FROM mongo

COPY mongos-setup.sh /setup.sh
RUN chmod +x /setup.sh

CMD ["/setup.sh"]
