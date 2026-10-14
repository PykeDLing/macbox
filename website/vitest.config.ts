import { defineConfig } from 'vitest/config';

export default defineConfig({
  define: { 'import.meta.env.APP_VERSION': JSON.stringify('0.0.0-test') },
  test: { include: ['tests/**/*.test.{ts,tsx}'], environment: 'node' },
});
