import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Chatbot Platform",
  description: "Multi-tenant chatbot platform",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
