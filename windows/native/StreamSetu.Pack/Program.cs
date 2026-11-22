using StreamSetu.Core;

// Build-time tool: StreamSetu.Pack <launcher.exe> <app folder> <version> <out.exe>
// Appends the app folder (as a zip) and its file list to the launcher, producing the one-file download.
if (args.Length != 4) { Console.Error.WriteLine("usage: StreamSetu.Pack <launcher.exe> <app folder> <version> <out.exe>"); return 2; }
Payload.Build(args[0], args[1], args[2], "StreamSetu.exe", args[3]);
Console.WriteLine($"{args[3]}: {new FileInfo(args[3]).Length} bytes");
return 0;
