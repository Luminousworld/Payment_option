
const express = require('express');
const bodyParser = require('body-parser');
const mongoose = require('mongoose');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const morgan = require('morgan');
const dotenv = require('dotenv');
const session = require('express-session');
const MongoStore = require('connect-mongo');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
const crypto = require('crypto');

// Load environment variables
dotenv.config();

// Initialize Express app
const app = express();

// Security middleware
app.use(helmet());
app.use(morgan('combined'));

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // limit each IP to 100 requests per windowMs
  message: 'Too many requests from this IP, please try again later'
});
app.use('/api/', limiter);
// Body parser
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Session configuration
app.use(session({
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  store: MongoStore.create({ mongoUrl: process.env.MONGO_URI }),
  cookie: {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    maxAge: 1000 * 60 * 60 * 24 * 7 // 1 week
  }
}));

// Connect to MongoDB
mongoose.connect(process.env.MONGO_URI, {
  useNewUrlParser: true,
  useUnifiedTopology: true
})
.then(() => console.log('MongoDB connected'))
.catch(err => console.error('MongoDB connection error:', err));

// Models
const Repair = require('./models/Repair');
const Product = require('./models/Product');
const Order = require('./models/Order');
const Customer = require('./models/Customer');
const Payment = require('./models/Payment');

// Product routes
app.use('/api/products', require('./routes/products'));

// Repair service routes
app.use('/api/repairs', require('./routes/repairs'));

// Customer routes
app.use('/api/customers', require('./routes/customers'));

// Order routes
app.use('/api/orders', require('./routes/orders'));

// ========================
// PAYMENT PROCESSING
// ========================

// Create payment intent for repairs
app.post('/api/payments/repair-intent', async (req, res) => {
  try {
    const { repairId, customerId, paymentMethod } = req.body;
    
    // Validate inputs
    if (!repairId || !customerId) {
      return res.status(400).json({ 
        success: false, 
        message: 'Missing required information' 
      });
    }
    
    // Get repair details
    const repair = await Repair.findById(repairId);
    if (!repair) {
      return res.status(404).json({ 
        success: false, 
        message: 'Repair record not found' 
      });
    }
    
    // Check customer
    const customer = await Customer.findById(customerId);
    if (!customer) {
      return res.status(404).json({ 
        success: false, 
        message: 'Customer not found' 
      });
    }
    
    // Calculate amount in cents
    const amount = Math.round(repair.totalCost * 100);
    
    // Create a PaymentIntent with the order amount and currency
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amount,
      currency: 'usd',
      customer: customer.stripeCustomerId,
      payment_method: paymentMethod,
      description: `Repair ID: ${repair._id} - ${repair.repairType} for ${repair.instrumentType}`,
      metadata: {
        repairId: repair._id.toString(),
        customerId: customer._id.toString(),
        instrumentType: repair.instrumentType,
        repairType: repair.repairType
      },
      receipt_email: customer.email
    });
    
    // Create payment record in database
    const payment = new Payment({
      customerId: customer._id,
      repairId: repair._id,
      amount: repair.totalCost,
      paymentIntentId: paymentIntent.id,
      status: 'pending',
      paymentMethod: paymentMethod ? 'card' : 'invoice',
      metadata: {
        description: `${repair.repairType} for ${repair.instrumentType}`,
        technician: repair.assignedTechnician
      }
    });
    
await payment.save();
    
    // Update repair status
    repair.paymentStatus = 'pending';
    await repair.save();
    
    res.status(200).json({
      success: true,
      clientSecret: paymentIntent.client_secret,
      paymentId: payment._id
    });
    
  } catch (error) {
    console.error('Payment intent creation error:', error);
    res.status(500).json({
      success: false,
      message: 'Payment processing error',
      error: process.env.NODE_ENV === 'development' ? error.message : 'Server error'
    });
  }
});

// Process payment for accessories or parts
app.post('/api/payments/product-order', async (req, res) => {
  try {
    const { items, customerId, shippingAddress, paymentMethod } = req.body;
    
    // Validate inputs
    if (!items || !items.length || !customerId) {
      return res.status(400).json({ 
        success: false, 
        message: 'Missing required information' 
      });
    }
    
    // Get customer
    const customer = await Customer.findById(customerId);
    if (!customer) {
      return res.status(404).json({ 
        success: false, 
        message: 'Customer not found' 
      });
    }
    
    // Get product details and calculate total
    const productIds = items.map(item => item.productId);
    const products = await Product.find({ _id: { $in: productIds } });
    
    // Create order items with validated products
    const orderItems = [];
    let subtotal = 0;
    
    for (const item of items) {
      const product = products.find(p => p._id.toString() === item.productId);
      if (!product) {
        return res.status(404).json({ 
          success: false, 
          message: `Product not found: ${item.productId}` 
        });
      }
      
      // Check inventory
      if (product.stockQuantity < item.quantity) {
        return res.status(400).json({ 
          success: false, 
          message: `Insufficient stock for product: ${product.name}` 
        });
      }
      
      const itemPrice = product.salePrice || product.regularPrice;
      const itemTotal = itemPrice * item.quantity;
      
      orderItems.push({
        productId: product._id,
        name: product.name,
        price: itemPrice,
        quantity: item.quantity,
        totalPrice: itemTotal
      });
       subtotal += itemTotal;
    }
    
    // Calculate tax and total
    const taxRate = 0.0825; // 8.25% tax rate
    const taxAmount = subtotal * taxRate;
    const shipping = subtotal > 100 ? 0 : 9.95; // Free shipping over $100
    const total = subtotal + taxAmount + shipping;
    
    // Create order
    const order = new Order({
      customerId: customer._id,
      items: orderItems,
      subtotal,
      tax: taxAmount,
      shippingFee: shipping,
      total,
      shippingAddress: shippingAddress || customer.address,
      status: 'pending'
    });
    
    await order.save();
    
    // Create Stripe PaymentIntent
    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(total * 100),
      currency: 'usd',
      customer: customer.stripeCustomerId,
      payment_method: paymentMethod,
      description: `Order ID: ${order._id} - Clarinet accessories/parts`,
      metadata: {
        orderId: order._id.toString(),
        customerId: customer._id.toString()
      },
      receipt_email: customer.email
    });
    
    // Create payment record
    const payment = new Payment({
      customerId: customer._id,
      orderId: order._id,
      amount: total,
      paymentIntentId: paymentIntent.id,
      status: 'pending',
      paymentMethod: paymentMethod ? 'card' : 'invoice',
      metadata: {
        items: orderItems.length,
        shipping: shipping > 0 ? 'standard' : 'free'
      }
    });
    
    await payment.save();
    
    // Update order with payment reference
    order.paymentId = payment._id;
    await order.save();
    
    res.status(200).json({
      success: true,
      orderId: order._id,
      clientSecret: paymentIntent.client_secret,
      paymentId: payment._id
    });
    
  } catch (error) {
    console.error('Order payment processing error:', error);
    res.status(500).json({
      success: false,
      message: 'Payment processing error',
      error: process.env.NODE_ENV === 'development' ? error.message : 'Server error'
    });
  }
});