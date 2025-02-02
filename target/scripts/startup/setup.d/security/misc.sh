#!/bin/bash

function _setup_security_stack
{
  _log 'debug' 'Setting up Security Stack'

  __setup__security__postgrey
  __setup__security__postscreen

  # recreate auto-generated file
  local DMS_AMAVIS_FILE=/etc/amavis/conf.d/61-dms_auto_generated

  echo "# WARNING: this file is auto-generated." >"${DMS_AMAVIS_FILE}"
  echo "use strict;" >>"${DMS_AMAVIS_FILE}"

  __setup__security__spamassassin
  __setup__security__clamav

  echo '1;  # ensure a defined return' >>"${DMS_AMAVIS_FILE}"
  chmod 444 "${DMS_AMAVIS_FILE}"

  __setup__security__fail2ban
  __setup__security__amavis
}

function __setup__security__postgrey
{
  if [[ ${ENABLE_POSTGREY} -eq 1 ]]
  then
    _log 'debug' 'Enabling and configuring Postgrey'

    sedfile -i -E \
      's|(^smtpd_recipient_restrictions =.*)|\1, check_policy_service inet:127.0.0.1:10023|' \
      /etc/postfix/main.cf

    sed -i -e \
      "s|\"--inet=127.0.0.1:10023\"|\"--inet=127.0.0.1:10023 --delay=${POSTGREY_DELAY} --max-age=${POSTGREY_MAX_AGE} --auto-whitelist-clients=${POSTGREY_AUTO_WHITELIST_CLIENTS}\"|" \
      /etc/default/postgrey

    if ! grep -i 'POSTGREY_TEXT' /etc/default/postgrey
    then
      printf 'POSTGREY_TEXT=\"%s\"\n\n' "${POSTGREY_TEXT}" >>/etc/default/postgrey
    fi

    if [[ -f /tmp/docker-mailserver/whitelist_clients.local ]]
    then
      cp -f /tmp/docker-mailserver/whitelist_clients.local /etc/postgrey/whitelist_clients.local
    fi

    if [[ -f /tmp/docker-mailserver/whitelist_recipients ]]
    then
      cp -f /tmp/docker-mailserver/whitelist_recipients /etc/postgrey/whitelist_recipients
    fi
  else
    _log 'debug' 'Postscreen is disabled'
  fi
}

function __setup__security__postscreen
{
  _log 'debug' 'Configuring Postscreen'
  sed -i \
    -e "s|postscreen_dnsbl_action = enforce|postscreen_dnsbl_action = ${POSTSCREEN_ACTION}|" \
    -e "s|postscreen_greet_action = enforce|postscreen_greet_action = ${POSTSCREEN_ACTION}|" \
    -e "s|postscreen_bare_newline_action = enforce|postscreen_bare_newline_action = ${POSTSCREEN_ACTION}|" /etc/postfix/main.cf

  if [[ ${ENABLE_DNSBL} -eq 0 ]]
  then
    _log 'debug' 'Disabling Postscreen DNSBLs'
    postconf 'postscreen_dnsbl_action = ignore'
    postconf 'postscreen_dnsbl_sites = '
  else
    _log 'debug' 'Postscreen DNSBLs are enabled'
  fi
}

function __setup__security__spamassassin
{
  if [[ ${ENABLE_SPAMASSASSIN} -eq 1 ]]
  then
    _log 'debug' 'Enabling and configuring SpamAssassin'

    # shellcheck disable=SC2016
    sed -i -r 's|^\$sa_tag_level_deflt (.*);|\$sa_tag_level_deflt = '"${SA_TAG}"';|g' /etc/amavis/conf.d/20-debian_defaults

    # shellcheck disable=SC2016
    sed -i -r 's|^\$sa_tag2_level_deflt (.*);|\$sa_tag2_level_deflt = '"${SA_TAG2}"';|g' /etc/amavis/conf.d/20-debian_defaults

    # shellcheck disable=SC2016
    sed -i -r 's|^\$sa_kill_level_deflt (.*);|\$sa_kill_level_deflt = '"${SA_KILL}"';|g' /etc/amavis/conf.d/20-debian_defaults

    # fix cron.daily for spamassassin
    sed -i \
      's|invoke-rc.d spamassassin reload|/etc/init\.d/spamassassin reload|g' \
      /etc/cron.daily/spamassassin

    if [[ ${SA_SPAM_SUBJECT} == 'undef' ]]
    then
      # shellcheck disable=SC2016
      sed -i -r 's|^\$sa_spam_subject_tag (.*);|\$sa_spam_subject_tag = undef;|g' /etc/amavis/conf.d/20-debian_defaults
    else
      # shellcheck disable=SC2016
      sed -i -r 's|^\$sa_spam_subject_tag (.*);|\$sa_spam_subject_tag = '"'${SA_SPAM_SUBJECT}'"';|g' /etc/amavis/conf.d/20-debian_defaults
    fi

    # activate short circuits when SA BAYES is certain it has spam or ham.
    if [[ ${SA_SHORTCIRCUIT_BAYES_SPAM} -eq 1 ]]
    then
      # automatically activate the Shortcircuit Plugin
      sed -i -r 's|^# loadplugin Mail::SpamAssassin::Plugin::Shortcircuit|loadplugin Mail::SpamAssassin::Plugin::Shortcircuit|g' /etc/spamassassin/v320.pre
      sed -i -r 's|^# shortcircuit BAYES_99|shortcircuit BAYES_99|g' /etc/spamassassin/local.cf
    fi

    if [[ ${SA_SHORTCIRCUIT_BAYES_HAM} -eq 1 ]]
    then
      # automatically activate the Shortcircuit Plugin
      sed -i -r 's|^# loadplugin Mail::SpamAssassin::Plugin::Shortcircuit|loadplugin Mail::SpamAssassin::Plugin::Shortcircuit|g' /etc/spamassassin/v320.pre
      sed -i -r 's|^# shortcircuit BAYES_00|shortcircuit BAYES_00|g' /etc/spamassassin/local.cf
    fi

    if [[ -e /tmp/docker-mailserver/spamassassin-rules.cf ]]
    then
      cp /tmp/docker-mailserver/spamassassin-rules.cf /etc/spamassassin/
    fi

    if [[ ${SPAMASSASSIN_SPAM_TO_INBOX} -eq 1 ]]
    then
      _log 'trace' 'Configuring Spamassassin/Amavis to send SPAM to inbox'

      sed -i "s|\$final_spam_destiny.*=.*$|\$final_spam_destiny = D_PASS;|g" /etc/amavis/conf.d/49-docker-mailserver
      sed -i "s|\$final_bad_header_destiny.*=.*$|\$final_bad_header_destiny = D_PASS;|g" /etc/amavis/conf.d/49-docker-mailserver
    else
      _log 'trace' 'Configuring Spamassassin/Amavis to bounce SPAM'

      sed -i "s|\$final_spam_destiny.*=.*$|\$final_spam_destiny = D_BOUNCE;|g" /etc/amavis/conf.d/49-docker-mailserver
      sed -i "s|\$final_bad_header_destiny.*=.*$|\$final_bad_header_destiny = D_BOUNCE;|g" /etc/amavis/conf.d/49-docker-mailserver
    fi

    if [[ ${ENABLE_SPAMASSASSIN_KAM} -eq 1 ]]
    then
      _log 'trace' 'Configuring Spamassassin KAM'
      local SPAMASSASSIN_KAM_CRON_FILE=/etc/cron.daily/spamassassin_kam

      sa-update --import /etc/spamassassin/kam/kam.sa-channels.mcgrail.com.key

      cat >"${SPAMASSASSIN_KAM_CRON_FILE}" <<"EOF"
#!/bin/bash

RESULT=$(sa-update --gpgkey 24C063D8 --channel kam.sa-channels.mcgrail.com 2>&1)
EXIT_CODE=${?}

# see https://spamassassin.apache.org/full/3.1.x/doc/sa-update.html#exit_codes
if [[ ${EXIT_CODE} -ge 4 ]]
then
  echo -e "Updating SpamAssassin KAM failed:\n${RESULT}\n" >&2
  exit 1
fi

exit 0

EOF

      chmod +x "${SPAMASSASSIN_KAM_CRON_FILE}"
    fi
  else
    _log 'debug' 'SpamAssassin is disabled'
    echo "@bypass_spam_checks_maps = (1);" >>"${DMS_AMAVIS_FILE}"
    rm -f /etc/cron.daily/spamassassin
  fi
}

function __setup__security__clamav
{
  if [[ ${ENABLE_CLAMAV} -eq 1 ]]
  then
    _log 'debug' 'Enabling and configuring ClamAV'

    local FILE
    for FILE in /var/log/mail/{clamav,freshclam}.log
    do
      touch "${FILE}"
      chown clamav:adm "${FILE}"
      chmod 640 "${FILE}"
    done

    if [[ ${CLAMAV_MESSAGE_SIZE_LIMIT} != '25M' ]]
    then
      _log 'trace' "Setting ClamAV message scan size limit to '${CLAMAV_MESSAGE_SIZE_LIMIT}'"
      sedfile -i \
        "s/^MaxFileSize.*/MaxFileSize ${CLAMAV_MESSAGE_SIZE_LIMIT}/" \
        /etc/clamav/clamd.conf
    fi
  else
    _log 'debug' 'Disabling ClamAV'
    echo '@bypass_virus_checks_maps = (1);' >>"${DMS_AMAVIS_FILE}"
    rm -f /etc/logrotate.d/clamav-* /etc/cron.d/clamav-freshclam
  fi
}

function __setup__security__fail2ban
{
  if [[ ${ENABLE_FAIL2BAN} -eq 1 ]]
  then
    _log 'debug' 'Enabling and configuring Fail2Ban'

    if [[ -e /tmp/docker-mailserver/fail2ban-fail2ban.cf ]]
    then
      cp /tmp/docker-mailserver/fail2ban-fail2ban.cf /etc/fail2ban/fail2ban.local
    fi

    if [[ -e /tmp/docker-mailserver/fail2ban-jail.cf ]]
    then
      cp /tmp/docker-mailserver/fail2ban-jail.cf /etc/fail2ban/jail.d/user-jail.local
    fi

    if [[ ${FAIL2BAN_BLOCKTYPE} != 'reject' ]]
    then
      echo -e '[Init]\nblocktype = drop' >/etc/fail2ban/action.d/nftables-common.local
    fi

    echo '[Definition]' >/etc/fail2ban/filter.d/custom.conf
  else
    _log 'debug' 'Fail2Ban is disabled'
    rm -f /etc/logrotate.d/fail2ban
  fi
}

function __setup__security__amavis
{
  if [[ ${ENABLE_AMAVIS} -eq 1 ]]
  then
    _log 'debug' 'Configuring Amavis'
    if [[ -f /tmp/docker-mailserver/amavis.cf ]]
    then
      cp /tmp/docker-mailserver/amavis.cf /etc/amavis/conf.d/50-user
    fi

    sed -i -E \
      "s|(log_level).*|\1 = ${AMAVIS_LOGLEVEL};|g" \
      /etc/amavis/conf.d/49-docker-mailserver

    cat /etc/dms/postfix/master.d/postfix-amavis.cf >>/etc/postfix/master.cf
    postconf 'content_filter = smtp-amavis:[127.0.0.1]:10024'

    sed -i \
      "s|^#\$myhostname = \"mail.example.com\";|\$myhostname = \"${HOSTNAME}\";|" \
      /etc/amavis/conf.d/05-node_id
  else
    _log 'debug' 'Disabling Amavis'

    _log 'trace' 'Disabling Amavis cron job'
    mv /etc/cron.d/amavisd-new /etc/cron.d/amavisd-new.disabled
    chmod 0 /etc/cron.d/amavisd-new.disabled

    if [[ ${ENABLE_CLAMAV} -eq 1 ]] && [[ ${ENABLE_RSPAMD} -eq 0 ]]
    then
      _log 'warn' 'ClamAV will not work when Amavis & rspamd are disabled. Enable either Amavis or rspamd to fix it.'
    fi

    if [[ ${ENABLE_SPAMASSASSIN} -eq 1 ]]
    then
      _log 'warn' 'Spamassassin will not work when Amavis is disabled. Enable Amavis to fix it.'
    fi
  fi
}
