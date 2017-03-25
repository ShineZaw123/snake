import asyncdispatch, asynchttpserver, asyncnet, future, logging, strutils

import websocket

import message

type
  Client = ref object
    socket: AsyncSocket
    connected: bool
    player: Player

  Server = ref object
    clients: seq[Client]

proc newClient(socket: AsyncSocket): Client =
  return Client(
    socket: socket,
    connected: true,
    player: initPlayer()
  )

proc `$`(client: Client): string =
  return "Client(nickname: $1, score: $2)" %
      [client.player.nickname, $client.player.score]

proc updateClients(server: Server) {.async.} =
  ## Updates each client with the current player scores every second.

  # TODO: Update only when something changed.
  while true:
    var newClients: seq[Client] = @[]
    var players: seq[Player] = @[]
    for client in server.clients:
      if not client.connected: continue

      players.add(client.player)
      newClients.add(client)

    # Overwrite with new list containing only connected clients.
    server.clients = newClients

    # Send the message to each client.
    let msg = createPlayerUpdateMessage(players)
    for client in server.clients:
      await client.socket.sendText(toJson(msg), false)

    info("$1 clients connected" % $server.clients.len)
    # Wait for 1 second.
    await sleepAsync(1000)

proc processMessage(client: Client, data: string) {.async.} =
  ## Process a single message.
  let msg = parseMessage(data)
  case msg.kind
  of MessageType.Hello:
    client.player.nickname = msg.nickname
    # Verify nickname is valid.
    # TODO: Check for swear words? :)
    if client.player.nickname.len notin 2 .. 8:
      warn("Bad nickname for ", $client)
      client.connected = false
  of MessageType.ScoreUpdate:
    client.player.score = msg.score
    # Validate score.
    if client.player.score.int notin 0 .. 9999:
      warn("Bad score for ", $client)
      client.connected = false
  of MessageType.PlayerUpdate:
    # The client shouldn't send this.
    client.connected = false

proc processClient(client: Client) {.async.} =
  ## Loop which continuously reads data from the client and processes the
  ## messages which are received.
  while client.connected:
    var frameFut = client.socket.readData(false)
    yield frameFut
    if frameFut.failed:
      error("Error occurred handling client messages.\n" &
            frameFut.error.msg)
      client.connected = false
      break

    let frame = frameFut.read()
    info("Received ", frame.opcode)
    if frame.opcode == Opcode.Text:
      await processMessage(client, frame.data)

  client.socket.close()

proc onRequest(server: Server, req: Request) {.async.} =
  let (success, error) = await verifyWebsocketRequest(req, "snake")
  if success:
    info("Client connected")
    server.clients.add(newClient(req.client))
    asyncCheck processClient(server.clients[^1])
  else:
    error("WS negotiation failed: " & error)
    await req.respond(Http400, "WebSocket negotiation failed: " & error)
    req.client.close()

when isMainModule:
  # Set up logging to console.
  var consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)

  # Set up a new `server` instance.
  let httpServer = newAsyncHttpServer()
  let server = Server(
    clients: @[]
  )

  # Launch the HTTP server.
  const port = Port(8080)
  info("Listening on port ", port.int)

  # TODO: Slightly annoying that I cannot just use future.=> here instead.
  # TODO: Ref https://github.com/nim-lang/Nim/issues/4753
  proc cb(req: Request): Future[void] {.async.} = await onRequest(server, req)

  asyncCheck updateClients(server)
  waitFor httpServer.serve(port, cb)