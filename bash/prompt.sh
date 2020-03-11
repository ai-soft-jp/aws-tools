# Prompt Helper
#
# usage:
#   . /opt/aws-tools/bash/prompt.sh
#   PROMPT_COMMAND="__prompt_setup"
#
# environs:
#   PSH_USER_COLOR      default: 34;1
#   PSH_ROOT_COLOR
#   PSH_HOST_COLOR      default: 31;4;1
#   PSH_PWDNAME         default: \w
#   PSH_PWDSTYLE        RHEL or Ubuntu
#   PSH_PWD_COLOR
#   PSH_SERVICE_NAME
#   PSH_SERVICE_COLOR   default: 38;5;15;48;5;1;1
#   PSH_ROLE_NAME
#   PSH_ROLE_COMMAND
#   PSH_ROLE_COLOR      default: 38;5;28;1
#   PSH_STATUS_NAME
#   PSH_STATUS_COMMAND
#   PSH_STATUS_COLOR    default:  38;5;21
#   PSH_USE_GIT_PROMPT
#   PSH_GIT_COLOR

__prompt_setup() {
  local EXITSTATUS=$?
  local USER_COLOR=${PSH_USER_COLOR:-34;1}
  local ROOT_COLOR=${PSH_ROOT_COLOR:-"$USER_COLOR"}
  local HOST_COLOR=${PSH_HOST_COLOR:-31;4;1}
  local PWDNAME=${PSH_PWDNAME:-'\w'}
  local PWDSTYLE=${PSH_PWDSTYLE:-Ubuntu}
  local PWD_COLOR=${PSH_PWD_COLOR}
  local SERVICE_NAME=${PSH_SERVICE_NAME}
  local SERVICE_COLOR=${PSH_SERVICE_COLOR:-38;5;15;48;5;1;1}
  local ROLE_NAME=${PSH_ROLE_NAME}
  local ROLE_COMMAND=${PSH_ROLE_COMMAND}
  local ROLE_COLOR=${PSH_ROLE_COLOR:-38;5;28;1}
  local STATUS_NAME=${PSH_STATUS_NAME}
  local STATUS_COMMAND=${PSH_STATUS_COMMAND}
  local STATUS_COLOR=${PSH_STATUS_COLOR:-38;5;21}
  local USE_GIT_PROMPT=${PSH_USE_GIT_PROMPT}
  local GIT_COLOR=${PSH_GIT_COLOR:-32}

  local TITLE='\u@\h: \w' PS1BUILD=

  if [[ -n "$SERVICE_NAME" ]]; then
    TITLE="[$SERVICE_NAME] $TITLE"
    if [[ -n "$SERVICE_COLOR" ]]; then
      PS1BUILD='\[\e['"$SERVICE_COLOR"'m\]'"$SERVICE_NAME"'\[\e[m\] '
    else
      PS1BUILD="$SERVICE_NAME "
    fi
  fi

  [[ -n "$ROLE_COMMAND" ]] && $ROLE_COMMAND
  if [[ -n "$ROLE_NAME" ]]; then
    if [[ -n "$ROLE_COLOR" ]]; then
      PS1BUILD="$PS1BUILD"'\[\e['"$ROLE_COLOR"'m\]'"$ROLE_NAME"'\[\e[m\] '
    else
      PS1BUILD="$PS1BUILD$ROLE_NAME "
    fi
  fi

  [[ -n "$STATUS_COMMAND" ]] && $STATUS_COMMAND
  if [[ -n "$STATUS_NAME" ]]; then
    if [[ -n "$STATUS_COLOR" ]]; then
      PS1BUILD="$PS1BUILD"'\[\e['"$STATUS_COLOR"'m\]'"$STATUS_NAME"'\[\e[m\] '
    else
      PS1BUILD="$PS1BUILD$STATUS_NAME "
    fi
  fi

  [[ "$PWDSTYLE" = Ubuntu ]] || PS1BUILD="${PS1BUILD}["
  if [[ -n "$USER_COLOR" ]]; then
    PS1BUILD="$PS1BUILD"'\[\e['"$USER_COLOR"'m\]\u\[\e[m\]'
  else
    PS1BUILD="$PS1BUILD"'\u'
  fi
  PS1BUILD="${PS1BUILD}@"
  if [[ -n "$HOST_COLOR" ]]; then
    PS1BUILD="$PS1BUILD"'\[\e['"$HOST_COLOR"'m\]\h\[\e[m\]'
  else
    PS1BUILD="$PS1BUILD"'\h'
  fi
  if [[ "$PWDSTYLE" = Ubuntu ]]; then
    PS1BUILD="${PS1BUILD}:"
  else
    PS1BUILD="$PS1BUILD "
  fi
  if [[ -n "$PWD_COLOR" ]]; then
    PS1BUILD="$PS1BUILD"'\[\e['"$PWD_COLOR"'m\]'"$PWDNAME"'\[\e[m\]'
  else
    PS1BUILD="$PS1BUILD$PWDNAME"
  fi
  if [[ -n "$USE_GIT_PROMPT" ]]; then
    if [[ "$USE_GIT_PROMPT" = yes ]]; then
      GIT_PROMPT=$(__git_ps1 '(%s)')
    else
      GIT_PROMPT=$(__git_ps1 "$USE_GIT_PROMPT")
    fi
    if [[ -n "$GIT_PROMPT" ]]; then
      if [[ -n "$GIT_COLOR" ]]; then
        PS1BUILD="$PS1BUILD"' \[\e['"$GIT_COLOR"'m\]'"$GIT_PROMPT"'\[\e[m\]'
      else
        PS1BUILD="$PS1BUILD $GIT_PROMPT"
      fi
    fi
  fi
  [[ "$PWDSTYLE" = Ubuntu ]] || PS1BUILD="${PS1BUILD}]"
  PS1BUILD="$PS1BUILD"'\$ '

  PS1='\[\e]0;'"$TITLE"'\a\]'"$PS1BUILD"

  return $EXITSTATUS
}
