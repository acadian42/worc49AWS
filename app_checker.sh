#!/bin/bash

# ---
# Script to find High Privilege Azure AD apps from App Governance
# and then query for their owners.
#
# Prerequisites:
# 1. Logged in with Azure CLI (`az login`)
# 2. User has Graph permissions: `AppGovernance.Read.All`, `Application.Read.All`
# 3. `jq` is installed (`sudo apt install jq`)
# ---

echo "Requesting Graph API access token from az cli..."

# Step 1: Get an access token for Microsoft Graph
# We use --output tsv to get the raw token, and -r in `read` to handle it.
read -r ACCESS_TOKEN < <(az account get-access-token --resource "https://graph.microsoft.com" --query accessToken --output tsv)

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Failed to get access token. Run 'az login' and ensure you have permissions."
    exit 1
fi

echo "Successfully got token. Querying App Governance..."

# Step 2: Query the App Governance API for "high" privilege apps
# This API endpoint is in beta.
# The filter `privilegeLevel eq 'high'` directly matches your request.
# The "Overprivileged" label is often represented by this high privilege status,
# especially when combined with data on unused permissions (which this API tracks).
HIGH_PRIV_APPS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
     "https://graph.microsoft.com/beta/appGovernance/apps?\$filter=privilegeLevel eq 'high'" \
     | jq -r '.value[] | @base64')

if [ -z "$HIGH_PRIV_APPS" ]; then
    echo "No high privilege apps found or API call failed."
    exit 0
fi

echo "Found high privilege apps. Now finding owners..."
echo "---"

# Step 3: Loop through each app and find its owner
for app_base64 in $HIGH_PRIV_APPS; do
    # Decode the base64 JSON blob for each app
    app=$(echo "$app_base64" | base64 --decode)

    APP_NAME=$(echo "$app" | jq -r '.displayName')
    APP_ID=$(echo "$app" | jq -r '.appId') # This is the App's Object ID

    echo "App Name: $APP_NAME"
    echo "App ID (Object ID): $APP_ID"

    # Step 4: Query the v1.0 /applications endpoint to get owners
    # Note: We use the App's Object ID (appId from prev query), not the Enterprise App ID
    APP_OWNERS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
         "https://graph.microsoft.com/v1.0/applications(appId='$APP_ID')/owners" \
         | jq -r '.value[] | .userPrincipalName // .displayName // " (Service Principal Owner)"')
    
    if [ -n "$APP_OWNERS" ]; then
        echo "Owners:"
        echo "$APP_OWNERS" | awk '{print "  - "$0}'
    else
        echo "Owners: None found"
    fi
    echo "---"
done
