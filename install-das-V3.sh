#!/bin/sh
set -e
set -x

sudo echo "deb http://s3.amazonaws.com/dev.hortonworks.com/DAS/ubuntu16/1.x/BUILDS/1.0.1.1-13 DAS main" > /etc/apt/sources.list.d/das.list
sudo apt-get update && sudo /usr/bin/apt-get -o Dpkg::Options::=--force-confdef --allow-unauthenticated --assume-yes install data-analytics-studio-lite
wget http://s3.amazonaws.com/dev.hortonworks.com/DAS/ubuntu16/1.x/BUILDS/1.0.1.1-13/tars/data_analytics_studio_lite/data-analytics-studio-mpack-1.0.1.1.0.1.1-13.tar.gz -O /tmp/data-analytics-studio-mpack.tar.gz
sudo ambari-server install-mpack --mpack=/tmp/data-analytics-studio-mpack.tar.gz

if [ -z $(sudo ambari-server status | grep -o "Ambari Server running") ]
then
    echo "${HOSTNAME} : Ambari is not running. Exiting"
    exit 0
else
    echo "${HOSTNAME}: Ambari is running. Proceed ahead."
fi
sudo ambari-server restart

CLUSTERNAME=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().deployment.cluster_name" | python)
echo "Cluster Name=$CLUSTERNAME"
USERID=$(echo -e "import hdinsight_common.Constants as Constants\nprint Constants.AMBARI_WATCHDOG_USERNAME" | python)
echo "USERID=$USERID"
PASSWD=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nimport hdinsight_common.Constants as Constants\nimport base64\nbase64pwd = ClusterManifestParser.parse_local_manifest().ambari_users.usersmap[Constants.AMBARI_WATCHDOG_USERNAME].password\nprint base64.b64decode(base64pwd)" | python)
TAG=$(cat /proc/sys/kernel/random/uuid)

#grep returns exit code 1 if no match is found. Suppress the error
set +e
if [ -z "$(curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" --silent -X GET https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/HIVE | grep HIVE_SERVER_INTERACTIVE)" ]
then
    LLAP=false
else
    LLAP=true
fi
set -e
echo "Interactive hive mode: $LLAP"
#Add service_name
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"ServiceInfo":{"service_name":"DATA_ANALYTICS_STUDIO"}}' https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services
#Add components
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d ''  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/DATA_ANALYTICS_STUDIO/components/DATA_ANALYTICS_STUDIO_WEBAPP
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d ''  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/DATA_ANALYTICS_STUDIO/components/DATA_ANALYTICS_STUDIO_EVENT_PROCESSOR
#Add configs
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-database", "tag": "$TAG","properties" : { "data_analytics_studio_database_port": "5432","data_analytics_studio_database_username": "das","data_analytics_studio_database_host": "","das_autocreate_db":"true", "pg_hba_conf_content": "local   all             {{data_analytics_studio_database_username}}                              md5\nhost    all             {{data_analytics_studio_database_username}}      0.0.0.0/0               md5\nhost    all             {{data_analytics_studio_database_username}}      ::/0                    md5\n\nlocal   all             postgres                                ident", "postgresql_conf_content": "listen_addresses = '\''*'\''\nport = {{data_analytics_studio_database_port}}\nmax_connections = 100\nshared_buffers = 128MB\ndynamic_shared_memory_type = posix\nlog_destination = '\''stderr'\''\nlogging_collector = on\nlog_directory = '\''pg_log'\''\nlog_filename = '\''postgresql-%a.log'\''\nlog_truncate_on_rotation = on\nlog_rotation_age = 1d\nlog_rotation_size = 0\nlog_line_prefix = '\''< %m > '\''\nlog_timezone = '\''UTC'\''\ndatestyle = '\''iso, mdy'\''\ntimezone = '\''UTC'\''\nlc_messages = '\''en_US.UTF-8'\''\nlc_monetary = '\''en_US.UTF-8'\''\nlc_numeric = '\''en_US.UTF-8'\''\nlc_time = '\''en_US.UTF-8'\''\ndefault_text_search_config = '\''pg_catalog.english'\''\n"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-logsearch-conf", "tag": "$TAG", "properties" : { "component_mappings":"DATA_ANALYTICS_STUDIO_WEBAPP:data_analytics_studio_webapp,data_analytics_studio_webapp_access;DATA_ANALYTICS_STUDIO_EVENT_PROCESSOR:data_analytics_studio_event_processor,data_analytics_studio_event_processor_access","content" : "{  \"input\":[    {      \"type\":\"data_analytics_studio_webapp\",      \"rowtype\":\"service\",      \"path\":\"{{default('\''/configurations/data_analytics_studio-env/data_analytics_studio_log_dir'\'','\''/var/log/das'\'')}}/das-webapp.log\"    },    {      \"type\": \"data_analytics_studio_event_processor\",      \"rowtype\":\"service\",      \"path\":\"{{default('\''/configurations/data_analytics_studio-env/data_analytics_studio_log_dir'\'', '\''/var/log/das'\'')}}/event-processor.log\"    }  ],  \"filter\":[    {      \"filter\":\"grok\",      \"conditions\":{        \"fields\":{          \"type\":[            \"data_analytics_studio_webapp\",            \"data_analytics_studio_event_processor\"          ]         }       },      \"log4j_format\":\"\",      \"multiline_pattern\":\"^(%{LOGLEVEL:level})\",      \"message_pattern\":\"(?m)^%{LOGLEVEL:level}%{SPACE}\\\\[%{TIMESTAMP_ISO8601:logtime}\\\\]%{SPACE}%{JAVACLASS:logger_name}:%{SPACE}%{GREEDYDATA:log_message}\",      \"post_map_values\":{        \"logtime\":{          \"map_date\":{            \"target_date_pattern\":\"yyyy-MM-dd HH:mm:ss,SSS\"          }         }       }     }   ] }","service_name": "Data Analytics Studio"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-webapp-properties", "tag": "$TAG", "properties" : { "data_analytics_studio_webapp_server_protocol": "http","data_analytics_studio_webapp_smartsense_id": "das-smartsense-id","data_analytics_studio_webapp_server_port": "30800","content": "{    \"logging\": {        \"level\": \"INFO\",        \"loggers\": {            \"com.hortonworks.hivestudio\": \"DEBUG\"        },        \"appenders\": [            {                \"type\": \"file\",                \"currentLogFilename\": \"{{data_analytics_studio_log_dir}}/das-webapp.log\",                \"archivedLogFilenamePattern\": \"{{data_analytics_studio_log_dir}}/das-webapp-%i.log.gz\",                \"archivedFileCount\": 5,                \"maxFileSize\": \"1GB\"            }        ]    },    \"jerseyClient\":{        },    \"database\": {        \"driverClass\": \"org.postgresql.Driver\",        \"url\": \"{{data_analytics_studio_database_jdbc_url}}\",        \"user\": \"{{data_analytics_studio_database_username}}\",        \"password\": \"{{data_analytics_studio_database_password}}\",        \"properties\": {        }    },    \"flyway\": {        \"schemas\": [\"das\"],        \"locations\": [            \"db/migrate/common\", \"db/migrate/prod\"        ]    },    \"server\": {        \"requestLog\": {            \"appenders\": [                {                    \"type\": \"file\",                    \"currentLogFilename\": \"{{data_analytics_studio_log_dir}}/das-webapp-access.log\",                    \"archivedLogFilenamePattern\": \"{{data_analytics_studio_log_dir}}/das-webapp-access-%i.log.gz\",                    \"archivedFileCount\": 5,                    \"maxFileSize\": \"1GB\"                }            ]        },        \"applicationConnectors\": [            {              {% if data_analytics_studio_ssl_enabled %}                \"keyStorePath\": \"{{data_analytics_studio_webapp_keystore_file}}\",                \"keyStorePassword\": \"{{data_analytics_studio_webapp_keystore_password}}\",                {# \"validateCerts\": true, #}              {% endif %}                \"type\": \"{{data_analytics_studio_webapp_server_protocol}}\",                \"port\": {{data_analytics_studio_webapp_server_port}}            }        ],        \"adminConnectors\": [            {              {% if data_analytics_studio_ssl_enabled %}                \"keyStorePath\": \"{{data_analytics_studio_webapp_keystore_file}}\",                \"keyStorePassword\": \"{{data_analytics_studio_webapp_keystore_password}}\",                {# \"validateCerts\": true, #}              {% endif %}                \"type\": \"{{data_analytics_studio_webapp_server_protocol}}\",                \"port\": {{data_analytics_studio_webapp_admin_port}}            }        ]    },    \"akka\": {        \"properties\": {            \"akka.loglevel\": \"INFO\",            \"akka.stdout-loglevel\": \"INFO\",            \"akka.actor.jdbc-connector-dispatcher.fork-join-executor.parallelism-factor\": 5.0,            \"akka.actor.result-dispatcher.fork-join-executor.parallelism-factor\": 10.0,            \"akka.actor.misc-dispatcher.fork-join-executor.parallelism-factor\": 5.0        }    },    \"gaConfiguration\": {        \"enabled\": true,        \"identifier\": \"UA-22950817-34\"    },    \"serviceConfigDirectory\" : \"/etc/das/conf/\",    \"environment\": \"production\",    \"smartsenseId\": \"{{data_analytics_studio_webapp_smartsense_id}}\",    \"authConfig\": {        \"enabled\": {{data_analytics_studio_webapp_auth_enabled}},        \"appUserName\": \"{{data_analytics_studio_user}}\",        \"adminUsers\": \"{{data_analytics_studio_admin_users}}\",        \"serviceAuthType\": \"{{data_analytics_studio_webapp_service_auth_type}}\",        \"serviceKeytab\": \"{{data_analytics_studio_webapp_service_keytab}}\",        \"servicePrincipal\": \"{{data_analytics_studio_webapp_service_principal}}\",        \"knoxSSOEnabled\": {{data_analytics_studio_webapp_knox_sso_enabled}},        \"knoxSSOUrl\": \"{{data_analytics_studio_webapp_knox_sso_url}}\",        \"knoxPublicKey\": \"{{data_analytics_studio_webapp_knox_publickey}}\",        \"knoxCookieName\": \"{{data_analytics_studio_webapp_knox_cookiename}}\",        \"knoxUrlParamName\": \"{{data_analytics_studio_webapp_knox_url_query_param}}\",        \"knoxUserAgent\": \"{{data_analytics_studio_webapp_knox_useragent}}\"    }}","data_analytics_studio_webapp_$USERID_port": "30801"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-event_processor-properties", "tag": "$TAG", "properties" : { "data_analytics_studio_event_processor_admin_server_port": "30901","data_analytics_studio_event_processor_server_protocol": "http","content": "{\n    \"logging\": {\n        \"level\": \"INFO\",\n        \"loggers\": {\n            \"com.hortonworks.hivestudio\": \"DEBUG\"\n        },\n        \"appenders\": [\n            {\n                \"type\": \"file\",\n                \"currentLogFilename\": \"{{data_analytics_studio_log_dir}}/event-processor.log\",\n                \"archivedLogFilenamePattern\": \"{{data_analytics_studio_log_dir}}/event-processor-%i.log.gz\",\n                \"archivedFileCount\": 5,\n                \"maxFileSize\": \"1GB\"\n            }\n        ]\n    },\n    \"jerseyClient\": {\n      \"timeout\": \"240s\",\n      \"connectionTimeout\": \"2s\"\n    },\n    \"database\": {\n        \"driverClass\": \"org.postgresql.Driver\",\n        \"url\": \"{{data_analytics_studio_database_jdbc_url}}\",\n        \"user\": \"{{data_analytics_studio_database_username}}\",\n        \"password\": \"{{data_analytics_studio_database_password}}\",\n        \"properties\": {\n        }\n    },\n    \"server\": {\n        \"requestLog\": {\n            \"appenders\": [\n                {\n                    \"type\": \"file\",\n                    \"currentLogFilename\": \"{{data_analytics_studio_log_dir}}/event-processor-access.log\",\n                    \"archivedLogFilenamePattern\": \"{{data_analytics_studio_log_dir}}/event-processor-access-%i.log.gz\",\n                    \"archivedFileCount\": 5,\n                    \"maxFileSize\": \"1GB\"\n                }\n            ]\n        },\n        \"applicationConnectors\": [\n            {\n              {% if data_analytics_studio_ssl_enabled %}\n                \"keyStorePath\": \"{{data_analytics_studio_event_processor_keystore_file}}\",\n                \"keyStorePassword\": \"{{data_analytics_studio_event_processor_keystore_password}}\",\n                {# \"validateCerts\": true, #}\n              {% endif %}\n                \"type\": \"{{data_analytics_studio_event_processor_server_protocol}}\",\n                \"port\": {{data_analytics_studio_event_processor_server_port}}\n            }\n        ],\n        \"adminConnectors\": [\n            {\n              {% if data_analytics_studio_ssl_enabled %}\n                \"keyStorePath\": \"{{data_analytics_studio_event_processor_keystore_file}}\",\n                \"keyStorePassword\": \"{{data_analytics_studio_event_processor_keystore_password}}\",\n                {# \"validateCerts\": true, #}\n              {% endif %}\n                \"type\": \"{{data_analytics_studio_event_processor_server_protocol}}\",\n                \"port\": {{data_analytics_studio_event_processor_admin_server_port}}\n            }\n        ]\n    },\n    \"akka\": {\n        \"properties\": {\n            \"akka.loglevel\": \"INFO\",\n            \"akka.stdout-loglevel\": \"INFO\",\n            \"akka.loggers.0\": \"akka.event.slf4j.Slf4jLogger\"\n        }\n    },\n    \"authConfig\": {\n        \"enabled\": {{data_analytics_studio_event_processor_auth_enabled}},\n        \"appUserName\": \"{{data_analytics_studio_user}}\",\n        \"serviceAuthType\": \"{{data_analytics_studio_event_processor_service_auth_type}}\",\n        \"serviceKeytab\": \"{{data_analytics_studio_event_processor_service_keytab}}\",\n        \"servicePrincipal\": \"{{data_analytics_studio_event_processor_service_principal}}\"\n    },\n    \"event-processing\": {\n        \"hive.hook.proto.base-directory\": \"{{data_analytics_studio_event_processor_hive_base_dir}}\",\n        \"tez.history.logging.proto-base-dir\": \"{{data_analytics_studio_event_processor_tez_base_dir}}\",\n        \"meta.info.sync.service.delay.millis\": 5000,\n        \"actor.initialization.delay.millis\": 20000,\n        \"close.folder.delay.millis\": 600000,\n        \"reread.event.max.retries\": -1,\n        \"reporting.scheduler.initial.delay.millis\": 30000,\n        \"reporting.scheduler.interval.delay.millis\": 300000,\n        \"reporting.scheduler.weekly.initial.delay.millis\": 60000,\n        \"reporting.scheduler.weekly.interval.delay.millis\": 600000,\n        \"reporting.scheduler.monthly.initial.delay.millis\": 90000,\n        \"reporting.scheduler.monthly.interval.delay.millis\": 900000,\n        \"reporting.scheduler.quarterly.initial.delay.millis\": 120000,\n        \"reporting.scheduler.quarterly.interval.delay.millis\": 1200000\n    },\n    \"serviceConfigDirectory\": \"/etc/das/conf/\",\n    \"environment\": \"production\"\n}","data_analytics_studio_event_processor_server_port": "30900"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-event_processor-env", "tag": "$TAG","properties" : { "content": "#!/usr/bin/env bash\n\n#Do NOT edit Log and Pid dir, modify Advanced data_analytics_studio-env properties instead\nexport DAS_EP_PID_DIR=\"{{data_analytics_studio_pid_dir}}\"\nexport DAS_EP_LOG_DIR=\"{{data_analytics_studio_log_dir}}\"\nexport JAVA_OPTS=\"{{data_analytics_studio_ep_jvm_opts}}\"\nexport ADDITIONAL_CLASSPATH=\"{{data_analytics_studio_ep_additional_classpath}}\"\n\nexport DEBUG=\"false\"\n#export DEBUG_PORT="}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-properties", "tag": "$TAG","properties" : { "hive_session_params": "","content": "application.name=das-webapp\nhive.session.params={{data_analytics_studio_hive_session_params}}\ndas.jobs.dir=/user/{{data_analytics_studio_user}}/jobs\ndas.api.url={{data_analytics_studio_webapp_server_url}}\nuse.hive.interactive.mode='$LLAP'"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-webapp-env", "tag": "$TAG","properties" : { "content": "#!/usr/bin/env bash\n\n#Do NOT edit Log and Pid dir, modify Advanced data_analytics_studio-env properties instead\nexport DAS_PID_DIR=\"{{data_analytics_studio_pid_dir}}\"\nexport DAS_LOG_DIR=\"{{data_analytics_studio_log_dir}}\"\nexport JAVA_OPTS=\"{{data_analytics_studio_webapp_jvm_opts}}\"\nexport ADDITIONAL_CLASSPATH=\"{{data_analytics_studio_webapp_additional_classpath}}\"\n\nexport DEBUG=\"false\"\n#export DEBUG_PORT="}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-security-site", "tag": "$TAG","properties" : { "webapp_keystore_file": "","authentication_enabled": "false","ssl_enabled": "false","knox_cookiename": "hadoop-jwt","knox_sso_enabled": "false","knox_url_query_param": "originalUrl","knox_useragent": "Mozilla,Chrome","event_processor_keystore_file": "","knox_publickey": "","admin_users": "hive","knox_sso_url": ""}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"type": "data_analytics_studio-env", "tag": "$TAG","properties" : { "data_analytics_studio_pid_dir": "/usr/das/1.0.1.0-11/data_analytics_studio","data_analytics_studio_log_dir":"/var/log/das","ep_jvm_opts": "-Xmx1024m","webapp_jvm_opts": "-Xmx1024m","webapp_additional_classpath" : "/usr/hdp/current/hadoop-client/*:/usr/hdp/current/hadoop-client/lib/wildfly-openssl-1.0.4.Final.jar:/usr/lib/rubix/*:/usr/lib/hdinsight-datalake/*","ep_additional_classpath" : "/usr/hdp/current/hadoop-client/*:/usr/hdp/current/hadoop-client/lib/wildfly-openssl-1.0.4.Final.jar:/usr/lib/rubix/*:/usr/lib/hdinsight-datalake/*"}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/configurations
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-database", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-logsearch-conf", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-webapp-properties", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-event_processor-properties", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-event_processor-env", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-properties", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-webapp-env", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-security-site", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{ "Clusters" : {"desired_configs": {"type": "data_analytics_studio-env", "tag" : "$TAG" }}}'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME
#assign hosts
NODENAME1=$(curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD --silent -H "X-Requested-By: ambari" -X GET https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts | grep -i hn0 | grep -i "host_name" | grep -o 'hn0.*' | sed 's/"//g')
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"host_components" : [{"HostRoles":{"component_name":"DATA_ANALYTICS_STUDIO_WEBAPP"}}] }'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts?Hosts/host_name=$NODENAME1
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"host_components" : [{"HostRoles":{"component_name":"DATA_ANALYTICS_STUDIO_EVENT_PROCESSOR"}}] }'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts?Hosts/host_name=$NODENAME1
NODENAME2=$(curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD --silent -H "X-Requested-By: ambari" -X GET https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts | grep -i hn1 | grep -i "host_name" | grep -o 'hn1.*' | sed 's/"//g')
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"host_components" : [{"HostRoles":{"component_name":"DATA_ANALYTICS_STUDIO_WEBAPP"}}] }'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts?Hosts/host_name=$NODENAME2
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X POST -d '{"host_components" : [{"HostRoles":{"component_name":"DATA_ANALYTICS_STUDIO_EVENT_PROCESSOR"}}] }'  https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/hosts?Hosts/host_name=$NODENAME2

#if secure, switch credentials to domain watchdog instead of cluster watchdog
SECURE_CLUSTER=$(echo -e "import hdinsight_common.Constants as Constants, hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().settings[Constants.ENABLE_SECURITY]" | python)
if [ "$SECURE_CLUSTER" == "true" ]
then
    USERID=$(echo -e "import hdinsight_common.Constants as Constants, hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().settings[Constants.DOMAIN_WATCHDOG_USER]" | python)
    PASSWD=$(echo -e "import hdinsight_common.Constants as Constants, hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().settings[Constants.DOMAIN_WATCHDOG_USER_PASSWORD]" | python)
    curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H 'X-Requested-By: ambari' -i -X POST -d '{"Credential" : { "principal" : '\""$USERID"\"', "key" : '\""$PASSWD"\"', "type" : "temporary"}}' https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/credentials/kdc.admin.credential
fi

#install service
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{"ServiceInfo": {"state" : "INSTALLED"}, "RequestInfo": {"context": "Install Data Analytics Studio"}}' https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/DATA_ANALYTICS_STUDIO
sleep 20s
curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{"ServiceInfo": {"state" : "INSTALLED"}, "RequestInfo": {"context": "Install Data Analytics Studio"}}' https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/DATA_ANALYTICS_STUDIO

sleep 120s
#start DATA ANALYTICS STUDO, retry 3 times if fails
n=0
SUCCESSCODE=202
RETRYCOUNT=3
STATUSCODE=400
until [ ! $STATUSCODE -gt $SUCCESSCODE ] || [ $n -gt $RETRYCOUNT ]
do
  STATUSCODE=$(curl --retry 5 --retry-delay 15 -u $USERID:$PASSWD -H "X-Requested-By: ambari" -i -X PUT -d '{"ServiceInfo": {"state" : "STARTED"}, "RequestInfo": {"context": "Start Data Analytics Studio"}}' --silent --write-out %{http_code} --output /tmp/response.txt https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/services/DATA_ANALYTICS_STUDIO)
  if ! test $STATUSCODE -gt $SUCCESSCODE; then
      
      break
  else
      sleep 10s
      n=$[$n+1]
  fi
done

if [ "$SECURE_CLUSTER" == "true" ]
then
	# Clean up temporary KDC credential we used to install DAS
	curl --retry 5 --retry-delay 15 -H "X-Requested-By:ambari" -u $USERID:$PASSWD -X DELETE https://$CLUSTERNAME-int.azurehdinsight.net/api/v1/clusters/$CLUSTERNAME/credentials/kdc.admin.credential
fi

if test $STATUSCODE -gt $SUCCESSCODE; then
  echo "Starting service failed for $CLUSTERNAME with $STATUSCODE"
  exit 1
fi
