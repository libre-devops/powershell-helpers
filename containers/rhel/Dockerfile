#Use supplier image
FROM registry.access.redhat.com/ubi9/ubi:latest

LABEL org.opencontainers.image.title=rhel
LABEL org.opencontainers.image.source=https://github.com/libre-devops/powershell-helpers

RUN rm -rf /bin/sh && ln -sf /bin/bash /bin/sh

#Set args with blank values - these will be over-written with the CLI
ARG NORMAL_USER=builder
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH="linux-x64"

#Set the environment with the CLI-passed arguements
ENV NORMAL_USER ${NORMAL_USER}
ENV DEBIAN_FRONTEND=noninteractive
ENV TARGETARCH ${TARGETARCH}

# Environment variables for pyenv
ENV HOME /home/${NORMAL_USER}
ENV PYENV_ROOT /home/${NORMAL_USER}/.pyenv
ENV PATH $PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH

#Set path vars
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt:/opt/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.local/bin:/home/${NORMAL_USER}/.local:/home/${NORMAL_USER}:/home/${NORMAL_USER}/.tenv:/home/${NORMAL_USER}/.tenv/bin:/home/${NORMAL_USER}/.pkenv:/home/${NORMAL_USER}/.pkenv/bin:/home/${NORMAL_USER}/.pyenv:/home/${NORMAL_USER}/.pyenv/bin:/home/${NORMAL_USER}/.pyenv/shims:/home/${NORMAL_USER}/.local/bin"
ENV PATHVAR="PATH=${PATH}"

# RHEL9 doesn't have readline-devel in the standard repos
ENV READLINE_DEVEL_VERSION="8.1-4"

#Declare user expectation, I am performing root actions, so use root.
USER root

#Install needed packages as well as setup python with args and pip
RUN useradd -ms /bin/bash ${NORMAL_USER} && \
    mkdir -p /home/linuxbrew && \
    chown -R ${NORMAL_USER}:${NORMAL_USER} /home/linuxbrew && \
    dnf update -y && dnf upgrade -y && dnf install -y yum-utils dnf sudo && \
    MAJOR_OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2 | cut -d '.' -f 1) && \
    rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR_OS_VERSION}.noarch.rpm && \
    /usr/bin/crb enable && \
    sudo dnf install -y \
    bash \
    bzip2-devel \
    ca-certificates \
    gcc \
    git \
    gnupg \
    gnupg2 \
    jq \
    libffi-devel \
    libicu-devel \
    make \
    nano \
    ncurses-devel \
    openssl-devel \
    procps-ng \
    sqlite-devel \
    unzip \
    wget \
    xz-devel \
    zip  \
    zlib-devel && \
    echo $PATHVAR > /etc/environment && \
    LATEST_VERSION=$(curl https://api.github.com/repos/sigstore/cosign/releases/latest | jq -r .tag_name | tr -d "v\", ") && \
    curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-${LATEST_VERSION}-1.x86_64.rpm" && \
    rpm -ivh cosign-${LATEST_VERSION}-1.x86_64.rpm && \
    curl -O https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/Packages/readline-devel-${READLINE_DEVEL_VERSION}.el9.x86_64.rpm && \
    dnf install -y readline-devel-${READLINE_DEVEL_VERSION}.el9.x86_64.rpm

RUN POWERSHELL_RELEASE_URL=$(curl -s -L https://api.github.com/repos/PowerShell/PowerShell/releases/latest | jq -r '.assets[] | select(.name | endswith("linux-x64.tar.gz")) | .browser_download_url') && \
    curl -L $POWERSHELL_RELEASE_URL -o /tmp/powershell.tar.gz && \
    mkdir -p /opt/microsoft/powershell/7 && \
    tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7 && \
    chmod +x /opt/microsoft/powershell/7/pwsh && \
    ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh && \
    ln -s /usr/bin/pwsh /usr/bin/powershell

RUN git clone https://github.com/pyenv/pyenv.git /home/${NORMAL_USER}/.pyenv && \
    eval "$(pyenv init --path)" && \
    pyenvLatestStable=$(pyenv install --list | grep -v - | grep -E "^\s*[0-9]+\.[0-9]+\.[0-9]+$" | tail -1) && \
    pyenv install $pyenvLatestStable && \
    pyenv global $pyenvLatestStable && \
    pip install --upgrade pip

#Install Azure Modules for Powershell - This can take a while, so setting as final step to shorten potential rebuilds
RUN pwsh -Command Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted && \
    pwsh -Command Install-Module -Name Az -Force -AllowClobber -Scope AllUsers -Repository PSGallery && \
    pwsh -Command Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers -Repository PSGallery && \
    pwsh -Command Install-Module -Name Pester -Force -AllowClobber -Scope AllUsers -Repository PSGallery && \
    pwsh -Command Install-Module -Name LibreDevOpsHelpers -Force -AllowClobber -Scope AllUsers -Repository PSGallery

RUN chown -R ${NORMAL_USER}:${NORMAL_USER} /opt && \
    chown -R ${NORMAL_USER}:${NORMAL_USER} /home/${NORMAL_USER}

USER ${NORMAL_USER}
WORKDIR /home/${NORMAL_USER}

RUN echo -en "\n" | /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/${NORMAL_USER}/.bashrc && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && \
    brew install gcc && \
    brew install pipx && \
    brew install azure-cli && \
    brew install tenv

RUN tenv tf install latest --verbose && \
    tenv tf use latest --verbose

SHELL ["pwsh", "-Command"]