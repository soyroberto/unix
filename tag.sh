#!/usr/bin/env bash

set -u

TAG_NAME="owner"
TAG_VALUE="soyroberto"

UNTAGGED_CSV="non-tagged-resources.csv"
FAILED_CSV="tagging-failures.csv"

TOTAL=0
TAGGED=0
ALREADY_TAGGED=0
FAILED=0
REMAINING=0
# CLI verification:
#az resource list \
#    --query "[].{Name:name,ResourceGroup:resourceGroup,Type:type,Owner:tags.owner}" \
#    -o table


# ------------------------------------------------------------
# CSV-safe function
# ------------------------------------------------------------

csv_escape() {
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

write_failure_csv() {
    local subscription="$1"
    local name="$2"
    local resource_group="$3"
    local resource_type="$4"
    local resource_id="$5"
    local error_message="$6"

    {
        csv_escape "$subscription"
        printf ','
        csv_escape "$name"
        printf ','
        csv_escape "$resource_group"
        printf ','
        csv_escape "$resource_type"
        printf ','
        csv_escape "$resource_id"
        printf ','
        csv_escape "$error_message"
        printf '\n'
    } >> "$FAILED_CSV"
}

write_untagged_csv() {
    local subscription="$1"
    local name="$2"
    local resource_group="$3"
    local resource_type="$4"
    local resource_id="$5"
    local current_owner="$6"

    {
        csv_escape "$subscription"
        printf ','
        csv_escape "$name"
        printf ','
        csv_escape "$resource_group"
        printf ','
        csv_escape "$resource_type"
        printf ','
        csv_escape "$resource_id"
        printf ','
        csv_escape "$current_owner"
        printf '\n'
    } >> "$UNTAGGED_CSV"
}

# ------------------------------------------------------------
# Validate Azure CLI login and subscription
# ------------------------------------------------------------

if ! az account show --output none 2>/dev/null; then
    echo "ERROR: Azure CLI is not logged in."
    echo "Run:"
    echo "  az login"
    exit 1
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"
SUBSCRIPTION_NAME="$(az account show --query name -o tsv 2>/dev/null)"
TENANT_ID="$(az account show --query tenantId -o tsv 2>/dev/null)"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
    echo "ERROR: No active Azure subscription was found."
    exit 1
fi

if ! az account set --subscription "$SUBSCRIPTION_ID"; then
    echo "ERROR: Could not select subscription:"
    echo "  $SUBSCRIPTION_ID"
    exit 1
fi

echo
echo "============================================================"
echo "AZURE RESOURCE TAGGING"
echo "============================================================"
echo "Subscription    : $SUBSCRIPTION_NAME"
echo "Subscription ID : $SUBSCRIPTION_ID"
echo "Tenant          : $TENANT_ID"
echo "Required tag    : $TAG_NAME=$TAG_VALUE"
echo "============================================================"
echo

# ------------------------------------------------------------
# Create report files
# ------------------------------------------------------------

printf '%s\n' \
    '"Subscription","ResourceName","ResourceGroup","ResourceType","ResourceId","CurrentOwner"' \
    > "$UNTAGGED_CSV"

printf '%s\n' \
    '"Subscription","ResourceName","ResourceGroup","ResourceType","ResourceId","Error"' \
    > "$FAILED_CSV"

# ------------------------------------------------------------
# Enumerate resource IDs
# ------------------------------------------------------------

RESOURCE_FILE="$(mktemp)"

if ! az resource list \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[].id" \
    --output tsv \
    > "$RESOURCE_FILE"; then

    echo "ERROR: Azure CLI could not enumerate resources."
    rm -f "$RESOURCE_FILE"
    exit 1
fi

RESOURCE_COUNT="$(grep -cve '^[[:space:]]*$' "$RESOURCE_FILE" || true)"

echo "Resources found : $RESOURCE_COUNT"
echo

# Critical safeguard against the previous false-success problem
if [[ "$RESOURCE_COUNT" -eq 0 ]]; then
    echo "ERROR: Azure CLI returned zero resources."
    echo
    echo "This script will not report success when nothing was enumerated."
    echo
    echo "Run these commands manually:"
    echo
    echo "  az account show --query '{Name:name,SubscriptionId:id,TenantId:tenantId}' -o table"
    echo "  az resource list --subscription \"$SUBSCRIPTION_ID\" --query '[].id' -o tsv"
    echo
    rm -f "$RESOURCE_FILE"
    exit 1
fi

# ------------------------------------------------------------
# Tag each resource
# ------------------------------------------------------------

while IFS= read -r RESOURCE_ID || [[ -n "$RESOURCE_ID" ]]; do

    RESOURCE_ID="${RESOURCE_ID//$'\r'/}"

    [[ -z "$RESOURCE_ID" ]] && continue

    TOTAL=$((TOTAL + 1))

    NAME="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query name \
        --output tsv 2>/dev/null || true)"

    RESOURCE_GROUP="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query resourceGroup \
        --output tsv 2>/dev/null || true)"

    RESOURCE_TYPE="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query type \
        --output tsv 2>/dev/null || true)"

    CURRENT_OWNER="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query tags.owner \
        --output tsv 2>/dev/null || true)"

    CURRENT_OWNER="${CURRENT_OWNER//$'\r'/}"

    if [[ "$CURRENT_OWNER" == "None" || "$CURRENT_OWNER" == "null" ]]; then
        CURRENT_OWNER=""
    fi

    echo "------------------------------------------------------------"
    echo "[$TOTAL/$RESOURCE_COUNT] ${NAME:-<unknown>}"
    echo "Resource Group : ${RESOURCE_GROUP:-<none>}"
    echo "Type           : ${RESOURCE_TYPE:-<unknown>}"
    echo "Resource ID    : $RESOURCE_ID"
    echo "Current owner  : ${CURRENT_OWNER:-<none>}"

    if [[ "$CURRENT_OWNER" == "$TAG_VALUE" ]]; then
        echo "STATUS         : ALREADY TAGGED"
        ALREADY_TAGGED=$((ALREADY_TAGGED + 1))
        continue
    fi

    TAG_URL="https://management.azure.com${RESOURCE_ID}/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"

    REQUEST_BODY='{
        "operation": "Merge",
        "properties": {
            "tags": {
                "owner": "roberto.lopezcastillo"
            }
        }
    }'

    echo "Action         : Applying $TAG_NAME=$TAG_VALUE"

    ERROR_OUTPUT="$(az rest \
        --method PATCH \
        --url "$TAG_URL" \
        --headers "Content-Type=application/json" \
        --body "$REQUEST_BODY" \
        --output none 2>&1)"

    EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 0 ]]; then
        echo "STATUS         : SUCCESS"
        TAGGED=$((TAGGED + 1))
    else
        echo "STATUS         : FAILED"
        echo "Azure error    : $ERROR_OUTPUT"

        FAILED=$((FAILED + 1))

        write_failure_csv \
            "$SUBSCRIPTION_NAME" \
            "$NAME" \
            "$RESOURCE_GROUP" \
            "$RESOURCE_TYPE" \
            "$RESOURCE_ID" \
            "$ERROR_OUTPUT"
    fi

done < "$RESOURCE_FILE"

rm -f "$RESOURCE_FILE"

# ------------------------------------------------------------
# Fresh verification pass
# ------------------------------------------------------------

echo
echo "============================================================"
echo "VERIFYING FINAL STATE"
echo "============================================================"
echo

VERIFY_FILE="$(mktemp)"

if ! az resource list \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[].id" \
    --output tsv \
    > "$VERIFY_FILE"; then

    echo "ERROR: Could not enumerate resources during verification."
    rm -f "$VERIFY_FILE"
    exit 1
fi

VERIFY_COUNT="$(grep -cve '^[[:space:]]*$' "$VERIFY_FILE" || true)"

if [[ "$VERIFY_COUNT" -eq 0 ]]; then
    echo "ERROR: Verification returned zero resources."
    echo "No success result will be reported."
    rm -f "$VERIFY_FILE"
    exit 1
fi

while IFS= read -r RESOURCE_ID || [[ -n "$RESOURCE_ID" ]]; do

    RESOURCE_ID="${RESOURCE_ID//$'\r'/}"

    [[ -z "$RESOURCE_ID" ]] && continue

    NAME="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query name \
        --output tsv 2>/dev/null || true)"

    RESOURCE_GROUP="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query resourceGroup \
        --output tsv 2>/dev/null || true)"

    RESOURCE_TYPE="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query type \
        --output tsv 2>/dev/null || true)"

    CURRENT_OWNER="$(az resource show \
        --ids "$RESOURCE_ID" \
        --query tags.owner \
        --output tsv 2>/dev/null || true)"

    CURRENT_OWNER="${CURRENT_OWNER//$'\r'/}"

    if [[ "$CURRENT_OWNER" == "None" || "$CURRENT_OWNER" == "null" ]]; then
        CURRENT_OWNER=""
    fi

    if [[ "$CURRENT_OWNER" != "$TAG_VALUE" ]]; then

        REMAINING=$((REMAINING + 1))

        echo "NOT TAGGED     : ${NAME:-<unknown>}"
        echo "Resource Group : ${RESOURCE_GROUP:-<none>}"
        echo "Type           : ${RESOURCE_TYPE:-<unknown>}"
        echo "Resource ID    : $RESOURCE_ID"
        echo "Current owner  : ${CURRENT_OWNER:-<none>}"
        echo

        write_untagged_csv \
            "$SUBSCRIPTION_NAME" \
            "$NAME" \
            "$RESOURCE_GROUP" \
            "$RESOURCE_TYPE" \
            "$RESOURCE_ID" \
            "$CURRENT_OWNER"
    fi

done < "$VERIFY_FILE"

rm -f "$VERIFY_FILE"

# ------------------------------------------------------------
# Final results
# ------------------------------------------------------------

echo
echo "============================================================"
echo "RESULTS"
echo "============================================================"
echo "Subscription    : $SUBSCRIPTION_NAME"
echo "Enumerated      : $RESOURCE_COUNT"
echo "Processed       : $TOTAL"
echo "Tagged          : $TAGGED"
echo "Already tagged  : $ALREADY_TAGGED"
echo "Failed attempts : $FAILED"
echo "Still untagged  : $REMAINING"
echo "============================================================"
echo
echo "Untagged report : $UNTAGGED_CSV"
echo "Failure report  : $FAILED_CSV"
echo

if [[ "$TOTAL" -ne "$RESOURCE_COUNT" ]]; then
    echo "ERROR: Enumeration mismatch."
    echo "Azure returned $RESOURCE_COUNT resources, but only $TOTAL were processed."
    exit 1
fi

if [[ "$REMAINING" -eq 0 && "$TOTAL" -gt 0 ]]; then
    echo "SUCCESS: All $TOTAL enumerated resources have:"
    echo "$TAG_NAME=$TAG_VALUE"
    exit 0
fi

echo "ATTENTION: $REMAINING resource(s) still lack the required owner value."
echo "Review:"
echo "  $UNTAGGED_CSV"
echo "  $FAILED_CSV"
exit 2
