#!/usr/bin/env python3
import os
import yaml
import getpass
from cryptography.fernet import Fernet
from pathlib import Path


def init_encryption_key(key_file=".fernet.key"):
    """Create encryption key if it doesn't exist"""
    key_path = Path(key_file)

    if not key_path.exists():
        print(f"Creating encryption key: {key_file}")
        key = Fernet.generate_key()
        key_path.write_bytes(key)
        os.chmod(key_path, 0o600)  # Only readable by owner
        print(f"✓ Key saved (permissions: 0o600)")

    return key_path.read_bytes()


def set_passwd(secrets_file, key_file=".fernet.key"):
    """
    Prompt user for password, encrypt it, and store in YAML file

    Args:
        secrets_file: Path to YAML file to store encrypted password
        key_file: Path to Fernet key file
    """
    key = init_encryption_key(key_file)
    cipher = Fernet(key)
    password = getpass.getpass("Enter password: ")
    password_confirm = getpass.getpass("Confirm password: ")
    if password != password_confirm:
        print("❌ Passwords don't match!")
        return False

    encrypted = cipher.encrypt(password.encode()).decode()
    secrets_path = Path(secrets_file)
    if secrets_path.exists():
        with open(secrets_path, "r") as f:
            secrets = yaml.safe_load(f) or {}
    else:
        secrets = {}

    secrets["password"] = encrypted
    with open(secrets_path, "w") as f:
        yaml.dump(secrets, f)

    os.chmod(secrets_path, 0o600)
    return True


def get_passwd(secrets_file, key_file=".fernet.key"):
    """
    Retrieve and decrypt password from YAML file

    Args:
        secrets_file: Path to YAML file containing encrypted password
        key_file: Path to Fernet key file

    Returns:
        Decrypted password string
    """
    key_path = Path(key_file)
    if not key_path.exists():
        raise FileNotFoundError(f"Encryption key not found: {key_file}")

    key = key_path.read_bytes()
    cipher = Fernet(key)
    secrets_path = Path(secrets_file)
    if not secrets_path.exists():
        raise FileNotFoundError(f"Secrets file not found: {secrets_file}")

    with open(secrets_path, "r") as f:
        secrets = yaml.safe_load(f)

    if "password" not in secrets:
        raise ValueError("No password found in secrets file")

    encrypted = secrets["password"]
    password = cipher.decrypt(encrypted.encode()).decode()
    return password
