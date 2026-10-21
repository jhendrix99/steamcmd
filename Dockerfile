# HXSHost SteamCMD runtime images.
#
# The parkervcp steamcmd images with one change: /entrypoint.sh, whose SteamCMD
# update step is bounded and self-repairing instead of able to hold a server
# offline forever. Everything else (Proton, libraries, the container user) is
# the base image, so these are drop-in: an egg switches by changing the image
# owner from parkervcp to jhendrix99 and nothing else.
#
#   ghcr.io/jhendrix99/steamcmd:debian  <- ghcr.io/parkervcp/steamcmd:debian
#   ghcr.io/jhendrix99/steamcmd:proton  <- ghcr.io/parkervcp/steamcmd:proton
ARG BASE=ghcr.io/parkervcp/steamcmd:debian
FROM ${BASE}
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh
USER container
