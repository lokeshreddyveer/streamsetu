import { LegalDocument } from "@/lib/legal";

export const metadata = { title: "Privacy Policy" };

export default function Page() {
  return <LegalDocument name="privacy" />;
}
