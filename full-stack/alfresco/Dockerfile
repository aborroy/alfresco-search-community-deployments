ARG ALFRESCO_TAG
FROM alfresco/alfresco-content-repository-community:${ALFRESCO_TAG}

ARG TOMCAT_DIR=/usr/local/tomcat

# The base image runs as the alfresco user; root is needed to install modules.
USER root

# ActiveMQ broker, required on the classpath even though the messaging subsystem is left
# switched off (-Dmessaging.subsystem.autoStart=false in compose.yaml). Fetched from Maven
# Central and checksum-verified rather than vendored into the repository.
ARG ACTIVEMQ_BROKER_VERSION=5.18.3
ARG ACTIVEMQ_BROKER_SHA256=e61a6989f91ecf961fb20452e9a893718102e97031500b8c27bd52779edf2308
RUN set -eux; \
    jar="activemq-broker-${ACTIVEMQ_BROKER_VERSION}.jar"; \
    curl -fsSL -o "/tmp/${jar}" \
      "https://repo1.maven.org/maven2/org/apache/activemq/activemq-broker/${ACTIVEMQ_BROKER_VERSION}/${jar}"; \
    echo "${ACTIVEMQ_BROKER_SHA256}  /tmp/${jar}" | sha256sum -c -; \
    mv "/tmp/${jar}" "${TOMCAT_DIR}/webapps/alfresco/WEB-INF/lib/${jar}"

# Drop your own extensions here. Both directories carry an `empty` placeholder so the COPY
# below succeeds on a clean checkout.
#   modules/amps  -> installed with the Alfresco Module Management Tool
#   modules/jars  -> copied straight onto the webapp classpath
RUN mkdir -p ${TOMCAT_DIR}/amps
COPY modules/amps ${TOMCAT_DIR}/amps
COPY modules/jars ${TOMCAT_DIR}/webapps/alfresco/WEB-INF/lib

RUN java -jar ${TOMCAT_DIR}/alfresco-mmt/alfresco-mmt*.jar install \
    ${TOMCAT_DIR}/amps ${TOMCAT_DIR}/webapps/alfresco -directory -nobackup -force

USER alfresco
