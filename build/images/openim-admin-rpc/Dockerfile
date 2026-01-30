# Using Alpine Linux for the final image
FROM alpine:latest

# Install necessary packages, such as bash
RUN apk add --no-cache bash

# Set the environment and work directory
ENV CHAT_DIR=/openim-chat
WORKDIR $CHAT_DIR


# Copy the compiled binaries and mage from the builder image to the final image
COPY ./_output/bin/platforms/linux/amd64/admin-rpc $CHAT_DIR/_output
COPY ./config $CHAT_DIR/config

# Set the command to run when the container starts
ENTRYPOINT ["sh", "-c", "_output/admin-rpc"]