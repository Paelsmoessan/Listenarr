/*
 * Listenarr - Audiobook Management System
 * Copyright (C) 2024-2026 Listenarr Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * Simple logger utility for consistent logging across the application
 * Logs are only output in development mode by default
 */

const isDev = import.meta.env.DEV

export const logger = {
  /**
   * Log debug information (only in development)
   */
  debug: (message: string, ...args: unknown[]) => {
    if (isDev) {
      console.log(`[DEBUG] ${message}`, ...args)
    }
  },

  /**
   * Log general information
   */
  info: (message: string, ...args: unknown[]) => {
    if (isDev) {
      console.info(`[INFO] ${message}`, ...args)
    }
  },

  /**
   * Log warnings
   */
  warn: (message: string, ...args: unknown[]) => {
    console.warn(`[WARN] ${message}`, ...args)
  },

  /**
   * Log errors
   */
  error: (message: string, ...args: unknown[]) => {
    console.error(`[ERROR] ${message}`, ...args)
  },

  /**
   * Log with a custom prefix/category
   */
  log: (category: string, message: string, ...args: unknown[]) => {
    if (isDev) {
      console.log(`[${category}] ${message}`, ...args)
    }
  },
}

/**
 * Namespaced logger that can be toggled ON AT RUNTIME even in a production build (our deployed DEV bundle
 * is a prod build, so `import.meta.env.DEV` is false and `logger.debug` is silent). Enable in the console:
 *   localStorage.setItem('la-debug', '1')          // all namespaces
 *   localStorage.setItem('la-debug', 'VG,VG/AV')   // only these namespaces
 *   localStorage.removeItem('la-debug')            // back to dev-only default
 * warn/error always print; debug/info honor the flag (falling back to isDev when the flag is unset).
 */
export class Logger {
  constructor(
    private readonly ns: string,
    private readonly force?: () => boolean,
  ) {}

  private enabled(): boolean {
    // Optional per-logger predicate wins (e.g. tie to a feature flag so no extra console command is needed).
    try {
      if (this.force?.()) return true
    } catch {
      /* predicate threw */
    }
    try {
      const flag = localStorage.getItem('la-debug')
      if (flag === '1' || flag === '*') return true
      if (flag === '0' || flag === 'false' || flag === 'off') return false // explicit off wins over isDev
      if (flag) return flag.split(',').some((n) => n.trim() === this.ns)
    } catch {
      /* localStorage may be unavailable */
    }
    return isDev
  }

  debug(message: string, ...args: unknown[]) {
    if (this.enabled()) console.log(`[${this.ns}] ${message}`, ...args)
  }

  info(message: string, ...args: unknown[]) {
    if (this.enabled()) console.info(`[${this.ns}] ${message}`, ...args)
  }

  warn(message: string, ...args: unknown[]) {
    console.warn(`[${this.ns}] ${message}`, ...args)
  }

  error(message: string, ...args: unknown[]) {
    console.error(`[${this.ns}] ${message}`, ...args)
  }
}

/**
 * Create a namespaced Logger (toggle at runtime via localStorage `la-debug`).
 * Pass `enabled` to force it on independently of the flag (e.g. tie to a feature flag).
 */
export function createLogger(ns: string, opts?: { enabled?: () => boolean }): Logger {
  return new Logger(ns, opts?.enabled)
}
