import { LegalDocument } from "@/lib/legal";

export const metadata = { title: "Open-Source Licenses" };

export default function Page() {
  return <LegalDocument name="licenses" />;
}
