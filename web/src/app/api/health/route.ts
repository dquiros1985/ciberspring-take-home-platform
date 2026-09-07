import { Client } from 'pg';
import { NextResponse } from 'next/server';

export async function GET() {
  const client = new Client({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: true },
    connectionTimeoutMillis: 8000,
  });
  try {
    await client.connect();
    const now = await client.query('SELECT now()');
    const count = await client.query('SELECT count(*) FROM app.documents');
    return NextResponse.json({
      now: now.rows[0].now,
      chunks: count.rows[0].count,
    });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  } finally {
    await client.end();
  }
}
