# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

# Ubuntu 20.04 (focal)
# https://hub.docker.com/_/ubuntu/?tab=tags&name=focal
ARG ROOT_CONTAINER=ubuntu:focal


FROM $ROOT_CONTAINER

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"
ARG NB_USER="discovery"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root


# Install all OS dependencies for notebook server that starts but lacks all
# features (e.g., download as all possible file formats)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update --yes && \
    # - apt-get upgrade is run to patch known vulnerabilities in apt-get packages as
    #   the ubuntu base image is rebuilt too seldom sometimes (less than once a month)
    apt-get upgrade --yes && \
    apt-get install --yes --no-install-recommends \
    ca-certificates \
    fonts-liberation \
    locales \
    # - pandoc is used to convert notebooks to html files
    #   it's not present in arm64 ubuntu image, so we install it here
    pandoc \
    # - run-one - a wrapper script that runs no more
    #   than one unique  instance  of  some  command with a unique set of arguments,
    #   we use `run-one-constantly` to support `RESTARTABLE` option
    run-one \
    sudo \
    # - tini is installed as a helpful container entrypoint that reaps zombie
    #   processes and such of the actual executable we want to start, see
    #   https://github.com/krallin/tini#why-tini for details.
    tini \
    wget && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

#add user discovery to sudo
#RUN adduser --disabled-password --gecos '' ${NB_USER}
#RUN usermod -a -G sudo ${NB_USER}
#RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers


# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

# Copy a script that we will use to correct permissions after running certain commands
COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
# hadolint ignore=SC2016
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc && \
   # Add call to conda init script see https://stackoverflow.com/a/58081608/4413446
   echo 'eval "$(command conda shell.bash hook 2> /dev/null)"' >> /etc/skel/.bashrc

# Create NB_USER with name discovery user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    sed -i.bak -e 's/^%admin/#%admin/' /etc/sudoers && \
    sed -i.bak -e 's/^%sudo/#%sudo/' /etc/sudoers && \
    useradd -l -m -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" && \
    mkdir -p "${CONDA_DIR}" && \
    chown "${NB_USER}:${NB_GID}" "${CONDA_DIR}" && \
    chmod g+w /etc/passwd && \
    fix-permissions "${HOME}" && \
    fix-permissions "${CONDA_DIR}"

RUN echo "discovery ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers

USER ${NB_UID}

ARG PYTHON_VERSION=3.10

# Setup work directory for backward-compatibility
RUN mkdir "/home/${NB_USER}/work" && \
    fix-permissions "/home/${NB_USER}"

# Install conda as discovery and check the sha256 sum provided on the download site
WORKDIR /tmp

# CONDA_MIRROR is a mirror prefix to speed up downloading
# For example, people from mainland China could set it as
# https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease
ARG CONDA_MIRROR=https://github.com/conda-forge/miniforge/releases/download/24.11.2-1

# ---- Miniforge installer ----
# Check https://github.com/conda-forge/miniforge/releases
# Package Manager and Python implementation to use (https://github.com/conda-forge/miniforge)
# We're using Mambaforge installer, possible options:
# - conda only: either Miniforge3 to use Python or Miniforge-pypy3 to use PyPy
# - conda + mamba: either Mambaforge to use Python or Mambaforge-pypy3 to use PyPy
# Installation: conda, mamba, pip
RUN set -x && \
    # Miniforge installer
    miniforge_arch=$(uname -m) && \
    miniforge_installer="Miniforge3-24.11.2-1-Linux-${miniforge_arch}.sh" && \
    wget --quiet "${CONDA_MIRROR}/${miniforge_installer}" && \
    /bin/bash "${miniforge_installer}" -f -b -p "${CONDA_DIR}" && \
    rm "${miniforge_installer}" && \
    # Conda configuration see https://conda.io/projects/conda/en/latest/configuration.html
    conda config --system --set auto_update_conda false && \
    conda config --system --set show_channel_urls true && \
    if [[ "${PYTHON_VERSION}" != "default" ]]; then mamba install --quiet --yes python="${PYTHON_VERSION}"; fi && \
    # Pin major.minor version of python
    mamba list python | grep '^python ' | tr -s ' ' | cut -d ' ' -f 1,2 >> "${CONDA_DIR}/conda-meta/pinned" && \
    # Using conda to update all packages: https://github.com/mamba-org/mamba/issues/1092
    conda update --all --quiet --yes && \
    conda clean --all -f -y && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Using fixed version of mamba in arm, because the latest one has problems with arm under qemu
# See: https://github.com/jupyter/docker-stacks/issues/1539
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" == "aarch64" ]; then \
        mamba install --quiet --yes \
            'mamba<0.18' && \
            mamba clean --all -f -y && \
            fix-permissions "${CONDA_DIR}" && \
            fix-permissions "/home/${NB_USER}"; \
    fi;

# Install Jupyter Notebook, Lab, and Hub
# Generate a notebook server config
# Cleanup temporary files
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
RUN mamba install --quiet --yes \
    'notebook' \
    'jupyterhub' \
    'jupyterlab' && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter notebook --generate-config && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

EXPOSE 8888

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start-notebook.sh"]

#update path
ENV PATH="/usr/bin:${PATH}"

# Copy local files as late as possible to avoid cache busting
COPY start.sh start-notebook.sh start-singleuser.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY jupyter_server_config.py /etc/jupyter/

#upgrade pip
RUN pip3 install --upgrade pip

#install spiderfoot
#RUN pip3 install CherryPy
#RUN sudo -S apt-get update && sudo -S apt-get install python3-pip
#RUN wget https://github.com/smicallef/spiderfoot/archive/v4.0.tar.gz -O /home/${NB_USER}/v4.0.tar.gz
#RUN tar zxvf /home/${NB_USER}/v4.0.tar.gz -C /home/${NB_USER}/
#RUN pip3 install -r /home/${NB_USER}/spiderfoot-4.0/requirements.txt
 
# COPY jupyter recon notebook to the work folder
COPY recon.ipynb /home/${NB_USER}/work/
#COPY zip.py /home/${NB_USER}/

#touch permutations, required by one of the cloud enum tools
RUN touch /home/${NB_USER}/work/permutations.txt


#install GO
#copying golang from their latest docker
 
COPY --from=golang:latest /usr/local/go/ /usr/local/go/
 

#RUN wget "https://go.dev/dl/$(curl 'https://go.dev/VERSION?m=text'|grep go).linux-amd64.tar.gz" -O /home/${NB_USER}/go.tar.gz
#RUN sudo -S rm -rf /usr/local/go && sudo -S tar -C /usr/local -xvf /home/${NB_USER}/go.tar.gz
#RUN sudo -S rm /home/${NB_USER}/go.tar.gz

#update path with GO path
ENV PATH="/usr/local/go/bin:${PATH}"


#install projectdiscovery recon tools and amass 
RUN sudo -S apt-get update && sudo -S apt-get -y install nmap curl jq gcc git
RUN mkdir ~/.config/ && mkdir ~/.config/subfinder
COPY provider-config.yaml ~/.config/subfinder/
RUN go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
RUN go install github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest
RUN go install github.com/projectdiscovery/httpx/cmd/httpx@latest
RUN go install github.com/owasp-amass/amass/v3/...@master
RUN go install github.com/projectdiscovery/chaos-client/cmd/chaos@latest


#trufflehog
RUN git clone https://github.com/trufflesecurity/trufflehog.git && cd trufflehog; go install
RUN rm trufflehog -R

#fff, gf, waybackurls  and anew from tomnomnom
RUN go install github.com/tomnomnom/anew@latest
RUN go install github.com/tomnomnom/gf@latest
RUN go install github.com/tomnomnom/fff@latest
RUN go install github.com/tomnomnom/waybackurls@latest
# increase your open file descriptor limit before doing anything crazy (tomnomnom)
RUN ulimit -n 16384

#gf patterns
RUN mkdir /home/${NB_USER}/.gf
RUN git clone https://github.com/tomnomnom/gf.git && cd gf/examples && cp -r * /home/${NB_USER}/.gf/ && cd ../../ && rm gf -r 
RUN git clone https://github.com/dwisiswant0/gf-secrets.git && cd gf-secrets/.gf && cp -r * /home/${NB_USER}/.gf/ && cd ../../ && rm gf-secrets -r

#smuggler
RUN git clone https://github.com/defparam/smuggler.git /home/${NB_USER}/smuggler
#crobat with go get
#RUN sudo -S apt-get -y install git
#RUN go env -w GO111MODULE=auto
#RUN go get github.com/cgboal/sonarsearch/cmd/crobat

RUN echo "Y" | sudo -S apt-get install zip
#shuffledns
RUN sudo -S apt-get install -y build-essential
RUN git clone --depth=1 https://github.com/blechschmidt/massdns.git && cd massdns && sudo -S make && sudo -S make install && cd .. && sudo -S rm massdns -R
RUN go install github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest

#dnsx
RUN go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest

#shodan's nrich
RUN wget https://gitlab.com/api/v4/projects/33695681/packages/generic/nrich/latest/nrich_latest_amd64.deb -O /home/${NB_USER}/nrich_latest_amd64.deb && \
         sudo dpkg -i /home/${NB_USER}/nrich_latest_amd64.deb && \
         rm /home/${NB_USER}/nrich_latest_amd64.deb

#dnsreaper, subdomain takeover
RUN git clone https://github.com/punk-security/dnsReaper.git /home/${NB_USER}/dnsReaper
RUN cd /home/${NB_USER}/dnsReaper && pip3 install -r requirements.txt
#RUN go install github.com/lukasikic/subzy@latest

#pymeta
RUN sudo -S apt-get install exiftool -y
RUN pip3 install pymetasec
#RUN git clone https://github.com/m8r0wn/pymeta /home/${NB_USER}/pymeta
#RUN cd /home/${NB_USER}/pymeta/ && python3 setup.py install

#confused - dependency scanner
RUN go install github.com/visma-prodsec/confused@latest

#katana
RUN go install github.com/projectdiscovery/katana/cmd/katana@latest

#deduplicate
RUN go install github.com/nytr0gen/deduplicate@latest


#parth & uro
RUN pip3 install parth
RUN pip3 install uro
 
RUN git clone https://github.com/s0md3v/XSStrike.git /home/${NB_USER}/XSStrike && pip3 install -r /home/${NB_USER}/XSStrike/requirements.txt

#GXss
RUN go install github.com/KathanP19/Gxss@latest

#Eyewitness screenshoting
RUN pip3 install selenium
RUN pip3 install fuzzywuzzy
RUN sudo -S ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime
ENV DEBIAN_FRONTEND=noninteractive 
RUN git clone --depth 1 https://github.com/FortyNorthSecurity/EyeWitness.git /home/${NB_USER}/EyeWitness
RUN sudo -S /home/${NB_USER}/EyeWitness/Python/setup/setup.sh
RUN pip3 install netaddr 
 
#RUN wget https://kali.download/kali/pool/main/e/eyewitness/eyewitness-dbgsym_20201210.7-0kali1_amd64.deb -O /home/${NB_USER}/eyewitness-dbgsym_20201210.7-0kali1_amd64.deb
#RUN sudo -S apt-get install -y gdebi-core && sudo -S gdebi /home/${NB_USER}/eyewitness-dbgsym_20201210.7-0kali1_amd64.deb && rm /home/${NB_USER}/eyewitness-dbgsym_20201210.7-0kali1_amd64.deb
#RUN sudo -S apt-get update && sudo -S apt-get install -y eyewitness
#RUN git clone https://github.com/FortyNorthSecurity/EyeWitness.git /home/${NB_USER}/EyeWitness/
#RUN /home/${NB_USER}/EyeWitness/Python/setup/setup.sh

#gowitness
#RUN go install github.com/sensepost/gowitness@latest
#RUN wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

#ffuf
RUN go install github.com/ffuf/ffuf@latest
RUN wget https://github.com/assetnote/commonspeak2-wordlists/raw/master/subdomains/subdomains.txt -O /home/${NB_USER}/commonspeak2.txt
RUN wget https://raw.githubusercontent.com/janmasarik/resolvers/master/resolvers.txt -O /home/${NB_USER}/resolvers.txt
RUN wget https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/directory-list-lowercase-2.3-small.txt -O /home/${NB_USER}/small.txt

#cloudenum tools
RUN git clone https://github.com/RhinoSecurityLabs/GCPBucketBrute.git /home/${NB_USER}/GCPBucketBrute/ && pip3 install -r /home/${NB_USER}/GCPBucketBrute/requirements.txt
RUN git clone https://github.com/initstring/cloud_enum.git /home/${NB_USER}/cloud_enum && pip3 install -r /home/${NB_USER}/cloud_enum/requirements.txt 

#Email enumeration
RUN git clone https://github.com/m8r0wn/crosslinked /home/${NB_USER}/crosslinked/ && pip3 install -r /home/${NB_USER}/crosslinked/requirements.txt
RUN sed -i -e 's/linkedin.com/au.linkedin.com/g' /home/${NB_USER}/crosslinked/crosslinked/search.py
#RUN echo Y |sudo -S apt-get install python3-requests
#RUN echo Y |sudo -S apt-get install python3-bs4
#RUN echo Y |sudo -S apt-get install python3-unidecode


#zip and excel python packages
#RUN pip3 install XlsxWriter
#RUN pip3 install openpyxl
#RUN pip3 install pandas
                

ENV PATH="/home/discovery/go/bin:${PATH}"

# Fix permissions on /etc/jupyter as root
USER root

# Legacy for Jupyter Notebook Server, see: [#1205](https://github.com/jupyter/docker-stacks/issues/1205)
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py && \
    fix-permissions /etc/jupyter/

# HEALTHCHECK documentation: https://docs.docker.com/engine/reference/builder/#healthcheck
# This healtcheck works well for `lab`, `notebook`, `nbclassic`, `server` and `retro` jupyter commands
# https://github.com/jupyter/docker-stacks/issues/915#issuecomment-1068528799
HEALTHCHECK  --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -O- --no-verbose --tries=1 http://localhost:8888/api || exit 1

#change ownership of scripts in bin directory
RUN chown ${NB_USER} /usr/local/bin/ -R && chmod u+rwx /usr/local/bin/ -R
# Switch back to discovery to avoid accidental container runs as root
USER ${NB_UID}

WORKDIR "${HOME}/work/"
