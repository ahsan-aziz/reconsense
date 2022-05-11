# External Network Recon using Jupyter Notebook
This is an effort to automate the external network reconnaissance part for penetration testing using Jupyter Notebook. A docker can be build using the Dockerfile which exposes two web services: Jupyter Notebook containing the open source recon tools and SpiderFoot (OSINT tool). 

To run:
```
git clone https://github.com/spaceintotime/recon.git

cd recon

sudo docker build -t jupyter -f Dockerfile .

sudo docker run -it --rm -p 8888:8888 -p 5001:5001 -e GRANT_SUDO=yes --user root jupyter:latest
```

After running the docker find the URLs for Jupyter (port 8888) and Spiderfoot (port 500) to launch the services. 
