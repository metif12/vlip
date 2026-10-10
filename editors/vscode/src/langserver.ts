import * as vscode from "vscode"
import {
	LanguageClient,
	type LanguageClientOptions,
	type ServerOptions,
} from "vscode-languageclient/node"

const serverId = "blip"
const serverName = "blip Language Server"
const configSection = "blip.server"
const defaultCommand = "blip"
const defaultArgs = ["lsp"]

function serverOptions(): ServerOptions {
	const config = vscode.workspace.getConfiguration(configSection)
	const command = config.get<string>("command", defaultCommand).trim()
	const args = config.get<string[]>("args", defaultArgs)
	return {
		command: command === "" ? defaultCommand : command,
		args,
	}
}

function clientOptions(): LanguageClientOptions {
	return {
		documentSelector: [{ scheme: "file", language: "blip" }],
		outputChannel: vscode.window.createOutputChannel(serverName),
		revealOutputChannelOn: vscode.RevealOutputChannelOn.Error,
	}
}

export function startServer(context: vscode.ExtensionContext): LanguageClient {
	const client = new LanguageClient(
		serverId,
		serverName,
		serverOptions(),
		clientOptions(),
	)
	context.subscriptions.push(client)
	client
		.start()
		.then(undefined, (error: unknown) => {
			void vscode.window.showErrorMessage(
				`blip: could not start the language server. Check the \`blip.server.command\` setting and the blip Language Server output. (${String(error)})`,
			)
		})
	return client
}
