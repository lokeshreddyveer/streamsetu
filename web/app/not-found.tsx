import Link from "next/link";

export default function NotFound() {
  return (
    <main className="wrap page narrow">
      <h1>Page not found</h1>
      <p className="lead">There is nothing at this address.</p>
      <p><Link className="button" href="/">Back to the home page</Link></p>
    </main>
  );
}
