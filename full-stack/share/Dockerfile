ARG SHARE_TAG
FROM alfresco/alfresco-share:${SHARE_TAG}

ARG TOMCAT_DIR=/usr/local/tomcat

ARG SERVER_NAME
ENV SERVER_NAME=$SERVER_NAME
ARG HTTP_PORT
ENV HTTP_PORT=$HTTP_PORT

# Drop your own extensions here. Both directories carry an `empty` placeholder so the COPY
# below succeeds on a clean checkout.
RUN mkdir -p $TOMCAT_DIR/amps
COPY modules/amps $TOMCAT_DIR/amps
COPY modules/jars $TOMCAT_DIR/webapps/share/WEB-INF/lib

RUN java -jar $TOMCAT_DIR/alfresco-mmt/alfresco-mmt*.jar install \
    $TOMCAT_DIR/amps $TOMCAT_DIR/webapps/share -directory -nobackup -force

# Raise the default Tomcat resource cache, which Share exceeds and logs warnings about.
RUN sed -i "s|<Context>|<Context>\n<Resources cacheMaxSize=\"51200\"/> |g" $TOMCAT_DIR/conf/context.xml

# Points Share at the repository over the proxy rather than directly.
COPY web-extension/share-config-custom-dev.xml $TOMCAT_DIR/shared/classes/alfresco/web-extension/
