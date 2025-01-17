#!/usr/bin/env bash
# Run this script once after bringing up gitea in docker compose
# TODO: add a check to detect that gitea has not fully initialized yet (no user relation error)
GITEA_USER=gitea_admin
GITEA_PASSWORD=admin1234
GITEA_USER_EMAIL=${GITEA_USER}@example.com
GITEA_NEW_ORGANIZATION=cerc-io
GITEA_URL_PREFIX=http://localhost:3000
CERC_GITEA_TOKEN_NAME=laconic-so-publication-token
CERC_GITEA_RUNNER_REGISTRATION_TOKEN=eMdEwIzSo87nBh0UFWZlbp308j6TNWr3WhWxQqIc
if [[ -n "$CERC_SCRIPT_DEBUG" ]]; then
    set -x
fi
# Create admin user
# First check if it already exists
if [[ -z ${CERC_SO_COMPOSE_PROJECT} ]] ; then
    compose_command="docker compose"
else
    compose_command="docker compose -p ${CERC_SO_COMPOSE_PROJECT}"
fi
sleep 15
${compose_command} exec --user git server gitea admin user list --admin | grep -v -e "^ID" | awk '{ print $2 }' | grep ${GITEA_USER} > /dev/null
if [[ $? == 1 ]] ; then
    # Then create if it wasn't found
    ${compose_command} exec --user git server gitea admin user create --admin --username ${GITEA_USER} --password ${GITEA_PASSWORD} --email ${GITEA_USER_EMAIL}
fi
# HACK: sleep a bit because if we don't gitea will return empty responses
sleep 5
# Check if the token already exists
token_response=$( curl -s "${GITEA_URL_PREFIX}/api/v1/users/${GITEA_USER}/tokens" \
  -u ${GITEA_USER}:${GITEA_PASSWORD} \
  -H "Content-Type: application/json")
if [[ -n ${token_response} ]] ; then
    echo ${token_response}  | jq --exit-status -r 'to_entries[] | select(.value.name == "'${CERC_GITEA_TOKEN_NAME}'")'
    if [[ $? == 0 ]] ; then
        token_found=1
    fi
fi
if [[ ${token_found} != 1 ]] ; then
    # Create access token if not found
    # Note that we either create the token here, or we needed to be passed 
    # the token by the caller. This is because gitea won't release the token
    # plaintext post-creation.
    new_gitea_token=$( curl -s -X POST "${GITEA_URL_PREFIX}/api/v1/users/${GITEA_USER}/tokens" \
      -u ${GITEA_USER}:${GITEA_PASSWORD} \
      -H "Content-Type: application/json" \
      -d '{"name":"'${CERC_GITEA_TOKEN_NAME}'", "scopes": [ "read:admin", "write:admin", "read:organization", "write:organization", "read:repository", "write:repository", "read:package", "write:package" ] }' \
      | jq -r .sha1 )
    echo "This is your gitea access token: ${new_gitea_token}. Keep it safe and secure, it can not be fetched again from gitea."
    echo "To use with laconic-so set this environment variable: export CERC_NPM_AUTH_TOKEN=${new_gitea_token}"
    CERC_GITEA_AUTH_TOKEN=${new_gitea_token}
else
    # If the token exists, then we must have been passed its value.
    # If we were not, then we fail hard here.
    if [[ -z ${CERC_GITEA_AUTH_TOKEN} ]] ; then
        echo "FATAL error: gitea auth token \"${CERC_GITEA_TOKEN_NAME}\" already exists but no CERC_GITEA_AUTH_TOKEN was provided"
        exit 1
    fi
fi
# Now that we're sure the token exists and is set in CERC_GITEA_AUTH_TOKEN,
# we can proceed with token-authenticated API requests below
# Create org
# First check if it already exists
curl -s "${GITEA_URL_PREFIX}/api/v1/admin/users/${GITEA_USER}/orgs" \
  -H "Authorization: token ${CERC_GITEA_AUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -H  "accept: application/json" \
  | jq --exit-status -r 'to_entries[] | select(.value.name == "'${GITEA_NEW_ORGANIZATION}'")' > /dev/null
if [[ $? != 0 ]] ; then
    # If it doesn't exist, create it
    # See: https://discourse.gitea.io/t/create-remove-organization-through-api/478
    curl -s -X POST "${GITEA_URL_PREFIX}/api/v1/admin/users/${GITEA_USER}/orgs" \
      -H "Authorization: token ${CERC_GITEA_AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      -H  "accept: application/json" \
      -d '{"username": "'${GITEA_NEW_ORGANIZATION}'"}' > /dev/null
    echo "Created the organization ${GITEA_NEW_ORGANIZATION}"
fi


# Seed a token for act_runner registration.
docker compose -p ${CERC_SO_COMPOSE_PROJECT} exec db psql -U gitea -d gitea -c "INSERT INTO public.action_runner_token(token, owner_id, repo_id, is_active, created, updated, deleted) VALUES('${CERC_GITEA_RUNNER_REGISTRATION_TOKEN}', 0, 0, 'f', 1679000000, 1679000000, NULL);" >/dev/null

echo "Gitea was configured to use host name: gitea.local, ensure that this resolves to localhost, e.g. with sudo vi /etc/hosts"
echo "Success, gitea is properly initialized"
