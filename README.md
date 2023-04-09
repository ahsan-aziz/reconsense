# External Network Recon using Jupyter Notebook
This is an effort to automate the external network reconnaissance part for penetration testing using Jupyter Notebook. A docker can be build using the Dockerfile which exposes a web service containing Jupyter Notebook. 

To run:
```
git clone https://github.com/spaceintotime/reconsense.git

cd reconsense

sudo docker build -t jupyter -f Dockerfile .

sudo docker run -it --rm -p 8888:8888 -e GRANT_SUDO=yes --user root jupyter:latest
```

After running the docker find the URL for Jupyter (port 8888) to launch the service. 

Checkout "recon.ipynb" file to see the preview of the jupyter notebook!
