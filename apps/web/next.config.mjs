/** @type {import('next').NextConfig} */
const nextConfig = {
  // Strict mode helps catch bugs early
  reactStrictMode: true,

  // Output as standalone for Docker deployments
  output: "standalone",
};

export default nextConfig;
