#!/usr/bin/env bash

# See: https://docs.wise.com/api-docs/features/strong-customer-authentication-2fa/personal-token-sca
# openssl genrsa -out certs/wise-private.pem 2048
# openssl rsa -pubout -in certs/wise-private.pem -out certs/wise-public.pem
PRIVATE_CERT='certs/wise-private.pem'

if [[ "$1" == "test" ]]; then
  URL_PREFIX='https://api.sandbox.transferwise.tech'
  echo '*** Using Sandbox API Environment'
else
  URL_PREFIX='https://api.transferwise.com'
fi

# Check for numeric year argument
if [[ "$1" =~ ^[0-9]{4}$ ]]; then
  SELECTED_YEAR="$1"
  echo -e "Downloading all statements for the year $SELECTED_YEAR"
fi


choose_and_set_id() {
  local output="$1"
  local i=1
  local id
  local value
  declare -A id_map
  declare -A value_map

  while read -r line; do
      id="${line##*: }"
      value="${line%: $id}"
      id_map[$i]=$id
      value_map[$i]=$value
      if [ "$id" == "$value" ]; then
        echo "$i: $id"
      else
        echo "$i: $value ($id)"
      fi
      ((i++))
  done <<< "$output"

  local choice
  while true; do
    read -p "Your choice: " -r choice
    # Check if the choice is non-empty and is a number in the valid range
    if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && -n "${id_map[$choice]}" ]]; then
      CHOSEN_ID="${id_map[$choice]}"
      CHOSEN_VALUE="${value_map[$choice]}"
      break
    else
      echo "*** Invalid input, please try again."
    fi
  done
}


perform_request() {
  local URI="$1"
  local FLAGS="$2"
  AUTH_HEADERS="-H \"Authorization: Bearer ${WISE_API_TOKEN}\" -H \"Content-Type: application/json\""
  # echo >&2 "############## CURL request:"
  # echo >&2 eval curl -s ${FLAGS} ${AUTH_HEADERS} "${URL_PREFIX}${URI}"
  # echo >&2 "############## CURL END"
  eval curl -s ${FLAGS} ${AUTH_HEADERS} "${URL_PREFIX}${URI}"
}

get_account_creation_year() {
    local all_accounts="$1"
    local account_id="$2"
    echo "$all_accounts" \
      | grep -F ": $account_id" \
      | sed -n "s/.*(\([0-9]\{4\}\)).*/\1/p"
}

extract_year_and_fullname() {
    local all_accounts="$1"
    local account_id="$2"

    # Skip year selection if SELECTED_YEAR is already set
    if [ -z "$SELECTED_YEAR" ]; then
        CREATION_YEAR=$(get_account_creation_year "$all_accounts" "$account_id")
        CURRENT_YEAR=$(date +%Y)
        YEAR_CHOICES=""
        for ((year=CREATION_YEAR; year<=CURRENT_YEAR; year++)); do
          YEAR_CHOICES+="$year\n"
        done
        echo -e "\nChoose year for the statement:"
        choose_and_set_id "$(echo -e "$YEAR_CHOICES")"
        SELECTED_YEAR=${CHOSEN_ID}
    fi

    # Extract account fullname for later
    ACCOUNT_FULLNAME=$(echo "$all_accounts" | grep -F ": $account_id" | sed -E 's/^([^:]+) \([0-9]{4}\): [0-9]+/\1/')
}

process_account() {
    local account_id="$1"
    local all_accounts="$2"
    local prefix="$3"

    CREATION_YEAR=$(get_account_creation_year "$all_accounts" "$account_id")
    extract_year_and_fullname "$all_accounts" "$account_id"

    if [[ "$CREATION_YEAR" -le "$SELECTED_YEAR" ]]; then
        echo -e "\nProcessing Account: ${ACCOUNT_FULLNAME}"
        CURRENCIES_OUTPUT=$(perform_request "/v4/profiles/${account_id}/balances?types=STANDARD" \
          | jq -r '.[] | "\(.currency): \(.id)"' | sort)
        while read -r currency_line; do
          WISE_BALANCE_ID="${currency_line##*: }"
          CURRENCY="${currency_line%: *}"
          if [ -z "$CURRENCY" ]; then
            echo "  * No statement available"
          else
            echo -n "  - ${CURRENCY}: "

            account_filename=$(echo "$ACCOUNT_FULLNAME" | sed 's/[^a-zA-Z0-9 ]//g' | tr -s " " | tr ' ' '_' | sed 's/^_//;s/_$//')
            OUTPUT_FILE_PREFIX="${prefix}/Wise-${account_id}-${account_filename}-${CURRENCY}-${SELECTED_YEAR}"
            echo -n "${OUTPUT_FILE_PREFIX}:"

            for extension in pdf xlsx csv; do
              STATEMENT_DETAILS="intervalStart=${SELECTED_YEAR}-01-01T00:00:00.000Z\&intervalEnd=${SELECTED_YEAR}-12-31T23:59:59.999Z\&type=COMPACT"
              OUTPUT=$(perform_request "/v1/profiles/${account_id}/balance-statements/${WISE_BALANCE_ID}/statement.${extension}?${STATEMENT_DETAILS}" "-I")

              REQ=$(echo "$OUTPUT" |  grep 'x-2fa-approval: ')
              REQ_ID=$(echo "${REQ##*: }" | tr -d '[:space:]')
              REQ_SIGNATURE=$(printf "${REQ_ID}" | openssl sha256 -sign ${PRIVATE_CERT} | openssl base64 -A | tr -d '\n')
              ADDITIONAL_HEADERS="-H \"x-2fa-approval: ${REQ_ID}\" -H \"X-Signature: ${REQ_SIGNATURE}\""

              echo -n " ${extension}"
              perform_request "/v1/profiles/${account_id}/balance-statements/${WISE_BALANCE_ID}/statement.${extension}?${STATEMENT_DETAILS}" "${ADDITIONAL_HEADERS} -o ${OUTPUT_FILE_PREFIX}.${extension}"
            done
            echo ""
          fi
        done <<< "$CURRENCIES_OUTPUT"
    else
        echo -e "\nSkipping: $ACCOUNT_FULLNAME (created in $CREATION_YEAR which is later than $SELECTED_YEAR)"
    fi
}


#####################################################################

if [ -z "${WISE_API_TOKEN}" ]; then
  read -s -p "WISE Personal API Token: " WISE_API_TOKEN
  echo
fi

uuid_regexp='(^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$)'
echo $WISE_API_TOKEN | grep -qE "${uuid_regexp}"
if [[ $? -ne 0 ]]; then
  echo "*** WRONG TOKEN FORMAT (${WISE_API_TOKEN})"
  exit 1
fi

ALL_ACCOUNTS=$(perform_request "/v2/profiles" \
  | jq -r '.[] | "\(.fullName) (\(.createdAt[0:4])): \(.id)"' | sort)

declare -A ACCOUNT_IDS
if [ -z "$SELECTED_YEAR" ]; then
    echo "Choose account:"
    choose_and_set_id "$ALL_ACCOUNTS"
    ACCOUNT_IDS["$CHOSEN_ID"]=1
else
    while read -r line; do
        id="${line##*: }"
        ACCOUNT_IDS["$id"]=1
    done <<< "$ALL_ACCOUNTS"
fi

# Loop through each account ID
DLDIR=~/Downloads/wise-statements
mkdir -p "$DLDIR"
for id in "${!ACCOUNT_IDS[@]}"; do
  process_account "$id" "$ALL_ACCOUNTS" "$DLDIR"
done

