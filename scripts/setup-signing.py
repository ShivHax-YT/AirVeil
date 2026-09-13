#!/usr/bin/env python3
"""Create AirVeil's persistent, local-only signing identity once per Mac."""
import os
from pathlib import Path
import secrets
import subprocess

root = Path(__file__).resolve().parent.parent
directory = Path.home() / "Library/Application Support/AirVeil/Signing"
sdk = os.environ.get("AIRVEIL_SDK", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
if not Path(sdk).is_dir():
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
os.umask(0o077)
(root / "build").mkdir(exist_ok=True)
helper = root / "build/signing-keychain"
subprocess.run(["/usr/bin/swiftc", "-suppress-warnings", "-sdk", sdk, str(root / "scripts/signing-keychain.swift"), "-o", str(helper)], check=True)
directory.mkdir(parents=True, exist_ok=True)
if (directory / "AirVeil.keychain-db").exists() or (directory / "certificate.pem").exists():
    raise SystemExit("Signing identity already exists. Keep it; replacing it would change app identity.")
password = secrets.token_hex(32)
(directory / "keychain-password").write_text(password)
config = directory / "certificate.cnf"
config.write_text("""[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = AirVeil Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)
try:
    run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes",
        "-sha256", "-days", "3650", "-config", str(config),
        "-keyout", str(directory / "private-key.pem"), "-out", str(directory / "certificate.pem"),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(directory / "private-key.pem"),
        "-in", str(directory / "certificate.pem"), "-out", str(directory / "identity.p12"),
        "-passout", "stdin", input=password.encode() + b"\n", stdout=subprocess.DEVNULL)
    run(str(helper), "create", str(directory))
    result = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(directory / "certificate.pem"),
                                      "-noout", "-fingerprint", "-sha1"], text=True)
    (directory / "identity-sha1").write_text(result.split("=", 1)[1].strip().replace(":", "") + "\n")
finally:
    for name in ("private-key.pem", "identity.p12", "certificate.cnf"):
        (directory / name).unlink(missing_ok=True)
print("Created persistent AirVeil signing identity outside the repository. No global trust settings changed.")
