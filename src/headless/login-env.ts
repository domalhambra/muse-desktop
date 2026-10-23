import { accessSync, constants } from 'node:fs'
import { fileURLToPath } from 'node:url'

/** The login-environment stub server.ts points SHELL at. Throws if a build left it out. */
export function loginEnvShell(base = new URL('./', import.meta.url)) {
  const path = fileURLToPath(new URL('login-env.sh', base))
  try {
    accessSync(path, constants.X_OK)
  } catch {
    throw new Error("mMac's backend is missing src/headless/login-env.sh.")
  }
  return path
}
