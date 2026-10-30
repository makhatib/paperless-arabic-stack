"""Django settings extension: upstream configuration plus explicit cookie protection."""
from paperless.settings import *  # noqa: F403
import os
from pathlib import Path

SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
SOCIALACCOUNT_EMAIL_AUTHENTICATION = False
SOCIALACCOUNT_EMAIL_AUTHENTICATION_AUTO_CONNECT = False
# Include the normal public roots: adding LAN trust must not break cloud OCR/mail.
if os.environ.get('PAS_CA_CERT'):
    bundle = Path(f'/tmp/pas-ca-bundle-{os.geteuid()}.pem')
    bundle.write_bytes(Path('/etc/ssl/certs/ca-certificates.crt').read_bytes() + b'\n' +
                       Path(os.environ['PAS_CA_CERT']).read_bytes())
    os.environ['REQUESTS_CA_BUNDLE'] = str(bundle)
    os.environ['SSL_CERT_FILE'] = str(bundle)
