import { createFileRoute } from '@tanstack/react-router';
import { homeHead } from '../../lib/head';

export const Route = createFileRoute('/_home/en/')({
  head: () => homeHead('en'),
});
