ARG BUILD_IMAGE="eclipse-temurin:21-jdk-alpine"
ARG BASE_IMAGE="eclipse-temurin:21-jre-alpine"

FROM $BUILD_IMAGE AS overlay

ARG EXT_BUILD_COMMANDS=""
ARG EXT_BUILD_OPTIONS=""

WORKDIR /cas-overlay
COPY ./src src/
COPY ./gradle/ gradle/
COPY ./gradlew ./settings.gradle ./build.gradle ./gradle.properties ./lombok.config ./

RUN mkdir -p ~/.gradle \
    && echo "org.gradle.daemon=false" >> ~/.gradle/gradle.properties \
    && echo "org.gradle.configureondemand=true" >> ~/.gradle/gradle.properties \
    && chmod 750 ./gradlew \
    && ./gradlew --version;

RUN ./gradlew clean build $EXT_BUILD_COMMANDS --parallel --no-daemon -Pexecutable=false -PjvmVendor=ADOPTIUM $EXT_BUILD_OPTIONS;

RUN java -Djarmode=tools -jar build/libs/cas.war extract \
    && java -XX:ArchiveClassesAtExit=./cas/cas.jsa -Dspring.context.exit=onRefresh -jar cas/cas.war

FROM $BASE_IMAGE AS cas

LABEL "Organization"="Apereo"
LABEL "Description"="Apereo CAS"

RUN apk upgrade --no-cache \
    && apk del --no-cache gnupg gnupg-dirmngr gnupg-gpgconf gnupg-keyboxd gnupg-utils gnupg-wks-client gpg gpg-agent gpg-wks-server gpgsm gpgv 2>/dev/null || true \
    && mkdir -p /etc/cas/config \
    && mkdir -p /etc/cas/services \
    && mkdir -p /etc/cas/saml

WORKDIR /cas-overlay
COPY --from=overlay /cas-overlay/cas cas/

COPY etc/cas/ /etc/cas/
COPY etc/cas/config/ /etc/cas/config/
COPY etc/cas/services/ /etc/cas/services/
COPY etc/cas/saml/ /etc/cas/saml/

EXPOSE 8080 8443

ENV PATH $PATH:$JAVA_HOME/bin:.

ENTRYPOINT ["java", "-server", "-noverify", "-Xmx2048M", "-XX:SharedArchiveFile=cas/cas.jsa", "-jar", "cas/cas.war"]
