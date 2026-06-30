'use strict';

require('dotenv').config();

const nodemailer = require('nodemailer');

async function main() {
  console.log('Testing pharmacy SES email...');
  console.log('SMTP_HOST:', process.env.SMTP_HOST);
  console.log('SMTP_PORT:', process.env.SMTP_PORT);
  console.log('EMAIL_FROM:', process.env.EMAIL_FROM);
  console.log('ORDER_NOTIFY_EMAIL:', process.env.ORDER_NOTIFY_EMAIL || process.env.EMAIL_TO);

  const transporter = nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: String(process.env.SMTP_SECURE || 'false') === 'true',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS
    }
  });

  const info = await transporter.sendMail({
    from: process.env.EMAIL_FROM,
    to: process.env.ORDER_NOTIFY_EMAIL || process.env.EMAIL_TO,
    subject: 'Pharmacy AI Test Email',
    text: 'This is a test email from the Vodia Pharmacy AI app using Amazon SES.'
  });

  console.log('Email sent successfully.');
  console.log({
    accepted: info.accepted,
    rejected: info.rejected,
    response: info.response,
    messageId: info.messageId
  });
}

main().catch(function (err) {
  console.error('Email test failed:');
  console.error(err);
  process.exit(1);
});
