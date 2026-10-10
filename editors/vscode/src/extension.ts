import * as vscode from "vscode"
import { startServer } from "./langserver"

const restartCommand = "blip.restartServer"

export function activate(context: vscode.ExtensionContext): void {
	let client = startServer(context)

	context.subscriptions.push(
		vscode.commands.registerCommand(restartCommand, async () => {
			await client.stop()
			client = startServer(context)
		}),
	)
}

export function deactivate(): void {}
