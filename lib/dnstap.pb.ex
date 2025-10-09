defmodule Dnstap.SocketFamily do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:INET, 1)
  field(:INET6, 2)
end

defmodule Dnstap.SocketProtocol do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:UDP, 1)
  field(:TCP, 2)
  field(:DOT, 3)
  field(:DOH, 4)
  field(:DNSCryptUDP, 5)
  field(:DNSCryptTCP, 6)
  field(:DOQ, 7)
end

defmodule Dnstap.HttpProtocol do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:HTTP1, 1)
  field(:HTTP2, 2)
  field(:HTTP3, 3)
end

defmodule Dnstap.Frame.Type do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:MESSAGE, 1)
end

defmodule Dnstap.Policy.Match do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:QNAME, 1)
  field(:CLIENT_IP, 2)
  field(:RESPONSE_IP, 3)
  field(:NS_NAME, 4)
  field(:NS_IP, 5)
end

defmodule Dnstap.Policy.Action do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:NXDOMAIN, 1)
  field(:NODATA, 2)
  field(:PASS, 3)
  field(:DROP, 4)
  field(:TRUNCATE, 5)
  field(:LOCAL_DATA, 6)
end

defmodule Dnstap.Message.Type do
  @moduledoc false

  use Protobuf, enum: true, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:AUTH_QUERY, 1)
  field(:AUTH_RESPONSE, 2)
  field(:RESOLVER_QUERY, 3)
  field(:RESOLVER_RESPONSE, 4)
  field(:CLIENT_QUERY, 5)
  field(:CLIENT_RESPONSE, 6)
  field(:FORWARDER_QUERY, 7)
  field(:FORWARDER_RESPONSE, 8)
  field(:STUB_QUERY, 9)
  field(:STUB_RESPONSE, 10)
  field(:TOOL_QUERY, 11)
  field(:TOOL_RESPONSE, 12)
  field(:UPDATE_QUERY, 13)
  field(:UPDATE_RESPONSE, 14)
end

defmodule Dnstap.Frame do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:identity, 1, optional: true, type: :bytes)
  field(:version, 2, optional: true, type: :bytes)
  field(:extra, 3, optional: true, type: :bytes)
  field(:type, 15, required: true, type: Dnstap.Frame.Type, enum: true)
  field(:message, 14, optional: true, type: Dnstap.Message)
end

defmodule Dnstap.Policy do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:type, 1, optional: true, type: :string)
  field(:rule, 2, optional: true, type: :bytes)
  field(:action, 3, optional: true, type: Dnstap.Policy.Action, enum: true)
  field(:match, 4, optional: true, type: Dnstap.Policy.Match, enum: true)
  field(:value, 5, optional: true, type: :bytes)
end

defmodule Dnstap.Message do
  @moduledoc false

  use Protobuf, protoc_gen_elixir_version: "0.15.0", syntax: :proto2

  field(:type, 1, required: true, type: Dnstap.Message.Type, enum: true)

  field(:socket_family, 2,
    optional: true,
    type: Dnstap.SocketFamily,
    json_name: "socketFamily",
    enum: true
  )

  field(:socket_protocol, 3,
    optional: true,
    type: Dnstap.SocketProtocol,
    json_name: "socketProtocol",
    enum: true
  )

  field(:query_address, 4, optional: true, type: :bytes, json_name: "queryAddress")
  field(:response_address, 5, optional: true, type: :bytes, json_name: "responseAddress")
  field(:query_port, 6, optional: true, type: :uint32, json_name: "queryPort")
  field(:response_port, 7, optional: true, type: :uint32, json_name: "responsePort")
  field(:query_time_sec, 8, optional: true, type: :uint64, json_name: "queryTimeSec")
  field(:query_time_nsec, 9, optional: true, type: :fixed32, json_name: "queryTimeNsec")
  field(:query_message, 10, optional: true, type: :bytes, json_name: "queryMessage")
  field(:query_zone, 11, optional: true, type: :bytes, json_name: "queryZone")
  field(:response_time_sec, 12, optional: true, type: :uint64, json_name: "responseTimeSec")
  field(:response_time_nsec, 13, optional: true, type: :fixed32, json_name: "responseTimeNsec")
  field(:response_message, 14, optional: true, type: :bytes, json_name: "responseMessage")
  field(:policy, 15, optional: true, type: Dnstap.Policy)

  field(:http_protocol, 16,
    optional: true,
    type: Dnstap.HttpProtocol,
    json_name: "httpProtocol",
    enum: true
  )
end
