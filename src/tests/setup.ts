// Load the Prisma mock before test files import application services.
import './prisma-mock';

// Fixed test-only value. Never used by the deployed application.
process.env.JWT_SECRET = 'unecont-unit-tests-only';
