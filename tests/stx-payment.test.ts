const request = require('supertest');
const mongoose = require('mongoose');
const app = require('../server'); // Ensure the correct path to your Express app file
const Payment = require('../models/Payment');
const Repair = require('../models/Repair');
const Customer = require('../models/Customer');
const Order = require('../models/Order');
const Product = require('../models/Product');

jest.mock('stripe');
const stripe = require('stripe');
stripe.paymentIntents.create = jest.fn().mockResolvedValue({
  id: 'pi_test',
  client_secret: 'secret_test'
});

describe('Payment API Tests', () => {
  let repair, customer, product;

  beforeAll(async () => {
    await mongoose.connect(process.env.MONGO_URI, {
      useNewUrlParser: true,
      useUnifiedTopology: true
    });
    
    customer = await Customer.create({
      name: 'Test Customer',
      email: 'test@example.com',
      stripeCustomerId: 'cus_test'
    });
    
    repair = await Repair.create({
      repairType: 'Fix Guitar',
      instrumentType: 'Guitar',
      totalCost: 100,
      assignedTechnician: 'Tech1',
      paymentStatus: 'pending'
    });
    
    product = await Product.create({
      name: 'Guitar Strings',
      regularPrice: 10,
      stockQuantity: 10
    });
  });

  afterAll(async () => {
    await mongoose.connection.dropDatabase();
    await mongoose.connection.close();
  });

  test('Should create a payment intent for repair', async () => {
    const res = await request(app)
      .post('/api/payments/repair-intent')
      .send({ repairId: repair._id, customerId: customer._id, paymentMethod: 'pm_card' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.clientSecret).toBe('secret_test');
  });

  test('Should fail if required fields are missing', async () => {
    const res = await request(app)
      .post('/api/payments/repair-intent')
      .send({ customerId: customer._id });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('Should process product order payment', async () => {
    const res = await request(app)
      .post('/api/payments/product-order')
      .send({
        items: [{ productId: product._id.toString(), quantity: 1 }],
        customerId: customer._id,
        shippingAddress: '123 Street',
        paymentMethod: 'pm_card'
      });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.orderId).toBeDefined();
  });
});
