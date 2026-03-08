import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import Home from "@/app/page";

describe("Home page", () => {
  it("renders the heading", () => {
    render(<Home />);
    expect(
      screen.getByRole("heading", { name: /chatbot platform/i })
    ).toBeDefined();
  });

  it("renders the description", () => {
    render(<Home />);
    const elements = screen.getAllByText(/coming soon/i);
    expect(elements.length).toBeGreaterThan(0);
  });
});
