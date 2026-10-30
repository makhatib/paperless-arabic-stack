"""Executed by manage.py shell with input JSON on stdin; never merge by email."""
import json
import sys
from allauth.socialaccount.models import SocialAccount
from django.contrib.auth import get_user_model
from django.db import transaction

config = json.load(sys.stdin)
with transaction.atomic():
    user = get_user_model().objects.get(username=config['paperless_username'])
    # Only the operator-selected existing administrator can receive the bootstrap link.
    if not user.is_superuser:
        raise RuntimeError('Bootstrap target is not an administrator')
    account, created = SocialAccount.objects.get_or_create(
        provider='authentik', uid=config['uid'], defaults={'user': user})
    if account.user_id != user.pk:
        raise RuntimeError('OIDC identity already belongs to a different account')
print('PAS_ADMIN_LINK_OK')
