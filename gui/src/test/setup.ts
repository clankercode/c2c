import { afterEach, vi } from "vitest";
import { cleanup } from "@testing-library/react";
import "@testing-library/jest-dom";

Element.prototype.scrollTo = vi.fn();
Element.prototype.getBoundingClientRect = vi.fn(() => ({
  bottom: 600,
  height: 600,
  left: 0,
  right: 800,
  top: 0,
  width: 800,
  x: 0,
  y: 0,
  toJSON: () => ({}),
}));

globalThis.ResizeObserver = class ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
};

afterEach(() => {
  cleanup();
});
