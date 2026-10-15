import { LegalDocument } from "@/lib/legal";

export const metadata = { title: "Terms of Use" };

export default function Page() {
  return <LegalDocument name="terms" />;
}
