// Exec target for the session-lock claim owner. All publication syscalls here
// run in the mutex holder itself, so they cannot outlive its claim.
import { randomBytes } from "node:crypto";
import {
  readFileSync, readdirSync, readlinkSync, renameSync, rmdirSync,
  unlinkSync, writeFileSync,
} from "node:fs";
import { dirname, basename, join } from "node:path";

const [lock, claimant, start, oldPid, pid, legacyProof, newProof] = process.argv.slice(2);
const claim = `${lock}.acquire`;
const base = dirname(lock);
const prefix = basename(lock);

function ownsClaim() {
  return readlinkSync(claim) === claimant
    && readFileSync(join(claimant, "pid"), "utf8") === `${process.pid}\n`
    && readFileSync(join(claimant, "start"), "utf8") === `${start}\n`;
}

function replace(path, content) {
  const temp = join(base, `${prefix}-write.${randomBytes(12).toString("hex")}`);
  try {
    writeFileSync(temp, content, { flag: "wx", mode: 0o600 });
    renameSync(temp, path);
  } catch (error) {
    try { unlinkSync(temp); } catch {}
    throw error;
  }
}

function readIfPresent(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return "";
    throw error;
  }
}

try {
  if (!ownsClaim()) throw new Error("acquisition mutex is no longer held");
  const seal = `${lock}.owner-format`;
  const format = readIfPresent(seal);
  if (!format) {
    if (legacyProof) replace(`${lock}.owner.${oldPid}`, `${legacyProof}\n`);
    replace(seal, "v1\n");
  } else if (format !== "v1\n") {
    throw new Error("unrecognized owner record format");
  }

  const proof = `${lock}.owner.${pid}`;
  replace(proof, `${newProof}\n`);
  if (readFileSync(proof, "utf8") !== `${newProof}\n`) {
    throw new Error("staged owner proof did not read back");
  }
  if (oldPid !== pid) replace(lock, `${pid}\n`);

  for (const name of readdirSync(base)) {
    if (((name.startsWith(`${prefix}-write.`) || name.startsWith(`${prefix}.owner.`))
        && name !== basename(proof)) || /^\.session-start-complete\.[a-f0-9]{64}$/.test(name)) {
      try { unlinkSync(join(base, name)); } catch {}
    }
  }
} catch (error) {
  console.error(`error: cannot publish session owner generation: ${error.message}`);
  process.exitCode = 1;
} finally {
  try {
    if (ownsClaim()) {
      unlinkSync(claim);
      unlinkSync(join(claimant, "pid"));
      unlinkSync(join(claimant, "start"));
      rmdirSync(claimant);
    }
  } catch {
    // A later claimant uses the normal abandoned-mutex recovery.
  }
}
