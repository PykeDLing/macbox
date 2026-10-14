import { createFileRoute } from '@tanstack/react-router';
import NotFound from '../views/NotFound';
import { notFoundTitle } from '../lib/head';

export const Route = createFileRoute('/404')({
  head: () => ({
    meta: [{ title: notFoundTitle }, { name: 'robots', content: 'noindex' }],
  }),
  component: NotFound,
});
