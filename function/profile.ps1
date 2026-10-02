# Runs on each cold start. Intentionally empty: Azure's default profile signs
# in with Connect-AzAccount, which needs the Az module this app doesn't ship.
# WardenSync signs in to Microsoft Graph itself with the managed identity.
