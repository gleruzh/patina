# Raw WebSocket rendezvous probe. Protobuf classes are generated from the
# pinned hbb_common protos (passed as the `protos` build context).
FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1
RUN pip install --no-cache-dir websockets==13.1 protobuf==5.28.3 grpcio-tools==1.68.1
WORKDIR /probe
COPY --from=protos rendezvous.proto /probe/proto/
RUN python -m grpc_tools.protoc -I/probe/proto --python_out=/probe /probe/proto/rendezvous.proto
COPY probe.py /probe/probe.py
ENTRYPOINT ["python", "-u", "/probe/probe.py"]
