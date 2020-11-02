#!/bin/sh
set -eu

execute_ssh(){
  echo "Execute Over SSH: $@"
  ssh -q -t -i "$HOME/.ssh/id_rsa" \
      -o UserKnownHostsFile=/dev/null \
      -p $INPUT_REMOTE_DOCKER_PORT \
      -o StrictHostKeyChecking=no "$INPUT_REMOTE_DOCKER_HOST" "$@"
}

if [ -z "$INPUT_REMOTE_DOCKER_PORT" ]; then
  INPUT_REMOTE_DOCKER_PORT=22
fi

if [ -z "$INPUT_REMOTE_DOCKER_HOST" ]; then
    echo "Input remote_docker_host is required!"
    exit 1
fi

if [ -z "$INPUT_SSH_PUBLIC_KEY" ]; then
    echo "Input ssh_public_key is required!"
    exit 1
fi

if [ -z "$INPUT_SSH_PRIVATE_KEY" ]; then
    echo "Input ssh_private_key is required!"
    exit 1
fi

if [ -z "$INPUT_ARGS" ]; then
  echo "Input input_args is required!"
  exit 1
fi

if [ -z "$INPUT_DEPLOY_PATH" ]; then
  INPUT_DEPLOY_PATH=~/docker-deployment
fi

if [ -z "$INPUT_STACK_FILE_NAME" ]; then
  INPUT_STACK_FILE_NAME=docker-compose.yaml
fi

if [ -z "$INPUT_KEEP_FILES" ]; then
  INPUT_KEEP_FILES=4
else
  INPUT_KEEP_FILES=$((INPUT_KEEP_FILES+1))
fi

STACK_FILE=${INPUT_STACK_FILE_NAME}
DEPLOYMENT_COMMAND_OPTIONS=""


if [ "$INPUT_COPY_STACK_FILE" == "true" ]; then
  STACK_FILE="$INPUT_DEPLOY_PATH/$STACK_FILE"
else
  DEPLOYMENT_COMMAND_OPTIONS=" --log-level debug --host ssh://$INPUT_REMOTE_DOCKER_HOST:$INPUT_REMOTE_DOCKER_PORT"
fi

case $INPUT_DEPLOYMENT_MODE in

  docker-swarm)
    DEPLOYMENT_COMMAND="docker $DEPLOYMENT_COMMAND_OPTIONS stack deploy --compose-file $STACK_FILE"
  ;;

  *)
    DEPLOYMENT_COMMAND="docker-compose $DEPLOYMENT_COMMAND_OPTIONS -f $STACK_FILE"
  ;;
esac


SSH_HOST=${INPUT_REMOTE_DOCKER_HOST#*@}

echo "Registering SSH keys..."

# register the private key with the agent.
mkdir -p "$HOME/.ssh"
printf '%s\n' "$INPUT_SSH_PRIVATE_KEY" > "$HOME/.ssh/id_rsa"
chmod 600 "$HOME/.ssh/id_rsa"
eval $(ssh-agent)
ssh-add "$HOME/.ssh/id_rsa"

echo "Add known hosts"
printf '%s %s\n' "$SSH_HOST" "$INPUT_SSH_PUBLIC_KEY" > /etc/ssh/ssh_known_hosts

if ! [ -z "$INPUT_DOCKER_PRUNE" ] && [ $INPUT_DOCKER_PRUNE = 'true' ] ; then
  yes | docker --log-level debug --host "ssh://$INPUT_REMOTE_DOCKER_HOST:$INPUT_REMOTE_DOCKER_PORT" system prune -a 2>&1
fi

if ! [ -z "$INPUT_COPY_STACK_FILE" ] && [ $INPUT_COPY_STACK_FILE = 'true' ] ; then
  execute_ssh "mkdir -p $INPUT_DEPLOY_PATH/stacks || true"
  FILE_NAME="docker-stack-$(date +%Y%m%d%s).yaml"

  scp -i "$HOME/.ssh/id_rsa" \
      -o UserKnownHostsFile=/dev/null \
      -o StrictHostKeyChecking=no \
      -P $INPUT_REMOTE_DOCKER_PORT \
      $INPUT_STACK_FILE_NAME "$INPUT_REMOTE_DOCKER_HOST:$INPUT_DEPLOY_PATH/stacks/$FILE_NAME"

  execute_ssh "ln -nfs $INPUT_DEPLOY_PATH/stacks/$FILE_NAME $INPUT_DEPLOY_PATH/$INPUT_STACK_FILE_NAME"
  execute_ssh "ls -t $INPUT_DEPLOY_PATH/stacks/docker-stack-* 2>/dev/null |  tail -n +$INPUT_KEEP_FILES | xargs rm --  2>/dev/null || true"

  if ! [ -z "$INPUT_PULL_IMAGES_FIRST" ] && [ $INPUT_PULL_IMAGES_FIRST = 'true' ] && [ $INPUT_DEPLOYMENT_MODE = 'docker-compose' ] ; then
    execute_ssh "${DEPLOYMENT_COMMAND} pull"
  fi

  if ! [ -z "$INPUT_PRE_DEPLOYMENT_COMMAND_ARGS" ] && [ $INPUT_DEPLOYMENT_MODE = 'docker-compose' ] ; then
    execute_ssh "${DEPLOYMENT_COMMAND}  $INPUT_PRE_DEPLOYMENT_COMMAND_ARGS" 2>&1
  fi

  execute_ssh ${DEPLOYMENT_COMMAND} "$INPUT_ARGS" 2>&1
else
  echo "Connecting to $INPUT_REMOTE_DOCKER_HOST... Command: ${DEPLOYMENT_COMMAND} ${INPUT_ARGS}"
  ${DEPLOYMENT_COMMAND} ${INPUT_ARGS} 2>&1
fi
