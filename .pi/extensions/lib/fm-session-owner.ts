// Shared Pi/omp adapter for the versioned session lock. The shell verifier owns
// the record, process lifetime checks and comparison with the private binding.
import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync } from "node:fs";
import { runCommandAsync } from "./fm-async-exec.ts";

type OwnerPaths = { root: string; home: string; state: string };
const bindingKeys = [
  "FM_SESSION_OWNER_HOME",
  "FM_SESSION_OWNER_PID",
  "FM_SESSION_OWNER_START",
  "FM_SESSION_OWNER_ID",
  "FM_SESSION_OWNER_KIND",
] as const;

export function usesLaunchOwners({ home, state }: OwnerPaths): boolean {
  try {
    lstatSync(`${state}/.lock.owner-format`);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return true;
  }
  try {
    const gate = `${home}/config/session-lock-owner`;
    return lstatSync(gate).isFile() && readFileSync(gate, "utf8").replace(/\n+$/, "") === "launch-v1";
  } catch {
    return false;
  }
}

function ownerEnv({ root, home, state }: OwnerPaths): NodeJS.ProcessEnv {
  return { ...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: root, FM_STATE_OVERRIDE: state };
}

export function bindNativeOwner(paths: OwnerPaths): boolean {
  if (!usesLaunchOwners(paths)) return true;
  if (process.env.FM_SESSION_OWNER_PID !== String(process.pid)) {
    // Direct adapter invocation binds to the engine itself. An inherited native
    // binding belongs to another engine and must never leak into its tool calls.
    const result = spawnSync(`${paths.root}/bin/fm-lock.sh`, ["bind-engine", String(process.pid)], {
      env: ownerEnv(paths),
      encoding: "utf8",
    });
    for (const key of bindingKeys) delete process.env[key];
    if (result.status !== 0) return false;
    const values = result.stdout.trimEnd().split("\n");
    if (values.length !== bindingKeys.length) return false;
    bindingKeys.forEach((key, i) => { process.env[key] = values[i]; });
  }
  spawnSync(`${paths.root}/bin/fm-lock.sh`, [], { env: ownerEnv(paths), stdio: "ignore" });
  return true;
}

export function verifyNativeOwner(paths: OwnerPaths): string {
  const result = spawnSync(`${paths.root}/bin/fm-lock.sh`, ["verify", String(process.pid)], {
    env: ownerEnv(paths),
    encoding: "utf8",
  });
  return result.status === 0 ? result.stdout.trim() : "";
}


export async function verifyNativeOwnerAsync(paths: OwnerPaths): Promise<string> {
  const result = await runCommandAsync(`${paths.root}/bin/fm-lock.sh`, ["verify", String(process.pid)], {
    env: ownerEnv(paths),
  });
  return result.status === 0 ? result.stdout.trim() : "";
}
