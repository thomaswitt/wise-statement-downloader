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

OUTPUT=$(perform_request "/v2/profiles" \
  | jq -r '.[] | "\(.fullName) (\(.createdAt[0:4])): \(.id)"' | sort)
echo "Choose account:"
choose_and_set_id "$OUTPUT"
WISE_P=${CHOSEN_ID}

# Extract the creation year of the account
ACCOUNT_CREATION_YEAR=$(echo "$OUTPUT" | sed -n "/$WISE_P/s/.*(\([0-9]\{4\}\)).*/\1/p")
CURRENT_YEAR=$(date +%Y)
YEAR_CHOICES=""
for ((year=ACCOUNT_CREATION_YEAR; year<=CURRENT_YEAR; year++)); do
  YEAR_CHOICES+="$year\n"
done

# Extract account fullname for later
ACCOUNT_FULLNAME=$(echo $CHOSEN_VALUE | sed 's/\(.*\) ([0-9]\{4\})/\1/' | sed 's/[^a-zA-Z0-9 ]//g' | tr -s " " | tr ' ' '_' | sed 's/^_//;s/_$//')

echo -e "\nChoose year for the statement:"
choose_and_set_id "$(echo -e "$YEAR_CHOICES")"
SELECTED_YEAR=${CHOSEN_ID}

OUTPUT=$(perform_request "/v4/profiles/${WISE_P}/balances?types=STANDARD" \
  | jq -r '.[] | "\(.currency) (\(.amount.value) \(.amount.currency)): \(.id)"' | sort)
echo -e "\nChoose currency:"
choose_and_set_id "$OUTPUT"
WISE_BALANCE_ID=${CHOSEN_ID}
CURRENCY=$(echo $CHOSEN_VALUE | sed 's/\(.*\) (.*).*/\1/')
echo "Chosen currency: ${CURRENCY}"

STATEMENT_DETAILS="intervalStart=${SELECTED_YEAR}-01-01T00:00:00.000Z\&intervalEnd=${SELECTED_YEAR}-12-31T23:59:59.999Z\&type=COMPACT"
OUTPUT=$(perform_request "/v1/profiles/${WISE_P}/balance-statements/${WISE_BALANCE_ID}/statement.pdf?${STATEMENT_DETAILS}" "-I") # -OJ / -o test.pdf w/o 2FA

REQ=$(echo "$OUTPUT" |  grep 'x-2fa-approval: ')
REQ_ID=$(echo "${REQ##*: }" | tr -d '[:space:]')
REQ_SIGNATURE=$(printf "${REQ_ID}" | openssl sha256 -sign ${PRIVATE_CERT} | openssl base64 -A | tr -d '\n')
ADDITIONAL_HEADERS="-H \"x-2fa-approval: ${REQ_ID}\" -H \"X-Signature: ${REQ_SIGNATURE}\""

OUTPUT_FILE="output/Wise-${WISE_P}-${ACCOUNT_FULLNAME}-${CURRENCY}-${SELECTED_YEAR}.pdf"
mkdir output >/dev/null 2>&1

echo -e "\n*** Writing PDF file to ${OUTPUT_FILE}"
perform_request "/v1/profiles/${WISE_P}/balance-statements/${WISE_BALANCE_ID}/statement.pdf?${STATEMENT_DETAILS}" "${ADDITIONAL_HEADERS} -o ${OUTPUT_FILE}"
