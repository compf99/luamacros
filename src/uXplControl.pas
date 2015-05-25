unit uXplControl;

interface

uses uXplCommon, Classes, uXplListener, uXplSender, uXplMessages, fgl;

type

  TCallbackInfoMap = TFPGMap<Int64,TLmcVariableCallbackInfo>;

  { TXPLcontrol }

  TXPLcontrol = class
  private
    fXplSyncListener: TXplListener; // for get var
    fXplAsyncListener: TXplListener; // for var callback
    fXplSender: TXplSender;
    fXplVariableValue: TXplVariableValue;
    fCallbacks: TCallbackInfoMap;
    procedure DebugLog(Value: String);
    procedure DebugLogFmt(pFormat:String; pArgs: array of const);
    procedure OnXplSyncMessage(Sender: TObject);
    procedure OnXplAsyncMessage(Sender: TObject);
  public
    { Public declarations }
    constructor Create;
    destructor Destroy; Override;
    procedure Init;
    function GetXplVariable(pName: String): TXplValue;
    procedure SetXplVariable(pName: String; pValue: TXplValue);
    procedure ExecuteCommand(pCmdName: String);
    procedure ExecuteCommandBegin(pCmdName: String);
    procedure ExecuteCommandEnd(pCmdName: String);
    procedure DrawText(pText: String; pPos: Single = 0; pSec: Integer = 5);
    procedure XplVarProcessed;
    procedure SetVariableHook(pVarName: String; pHandlerRef: Integer; pIntervalMs: Integer);
  end;

  TXPLRefHolder = class
  private
    fData: Pointer8b;
  public
    property Data: Pointer8b read fData write fData;
  end;



implementation

uses SysUtils, Windows, Forms, XPLMDataAccess, Variants,
  uGlobals;

{ TXPLcontrol }

constructor TXPLcontrol.Create;
begin
  //lGlb.DebugLog('Xplane control created.', 'XPL');
  fXplSyncListener := TXplListener.Create(cXplToLmcPipeName);
  fXplSyncListener.OnMessage:=OnXplSyncMessage;
  fXplAsyncListener := TXplListener.Create(cXplToLmcAsyncPipeName);
  fXplAsyncListener.OnMessage:=OnXplAsyncMessage;
  fXplSender := TXplSender.Create(cLmcToXplPipeName);
  fXplSender.DebugMethod:=DebugLogFmt;
  fXplVariableValue := nil;
  fCallbacks := TCallbackInfoMap.Create;
end;

procedure TXPLcontrol.DebugLog(Value: String);
begin
  if Glb <> nil then
    Glb.DebugLog(Value, cLoggerXpl);
end;

procedure TXPLcontrol.DebugLogFmt(pFormat: String; pArgs: array of const);
begin
  if Glb <> nil then
    Glb.DebugLogFmt(pFormat, pArgs, cLoggerXpl);
end;

destructor TXPLcontrol.Destroy;
var I: Integer;
begin
  fXplSyncListener.Free;
  fXplAsyncListener.Free;
  fXplSender.Free;
  for I := fCallbacks.Count - 1 downto 0 do
    fCallbacks.Data[I].Free;
  fCallbacks.Free;
  inherited;
end;

procedure TXPLcontrol.Init;
begin
  fXplSyncListener.Init;
  fXplAsyncListener.Init;
  if (fXplSender.ServerRunning) then
  begin
    // Xplane is already running, could be connected to wrong previous LMC instance
    // Send reconnect command to be sure
    fXplSender.SendMessage(TXplReconnectToServer.Create);
  end;
  //lGlb.DebugLog(Format('Slot size: %d, mem size: %d', [SizeOf(TXplComSlot), SizeOf(TXplComRecord)]), 'XPL');
end;

procedure TXPLcontrol.DrawText(pText: String; pPos: Single; pSec: Integer);
var
  lXplText: TXplDrawText;
begin
  lXplText := TXplDrawText.Create(pText);
  lXplText.TimeInSec:=pSec;
  lXplText.Position:=pPos;
  DebugLog(Format('Sending DrawText command for text %s at pos %f.', [pText, pPos]));
  fXplSender.SendMessage(lXplText);
  lXplText.Free;
end;

procedure TXPLcontrol.XplVarProcessed;
begin
  if fXplVariableValue <> nil then
  begin
    fXplVariableValue.Free;
    fXplVariableValue := nil;
  end else
    Glb.LogError('Value from XPL should be markes as processed, but there''s no such value', cLoggerXpl);
end;

procedure TXPLcontrol.SetVariableHook(pVarName: String; pHandlerRef: Integer;
  pIntervalMs: Integer);
var
  lXplObj: TXplVariableCallback;
  lCbInfo: TLmcVariableCallbackInfo;
  lId: Int64;
begin
  lId:=Glb.KeyLogService.UnixTimestampMs;
  lXplObj := TXplVariableCallback.Create(pVarName, pIntervalMs, lId);
  fXplSender.SendMessage(lXplObj);
  lCbInfo := TLmcVariableCallbackInfo.Create;
  lCbInfo.Id:=lId;
  lCbInfo.Interval:=pIntervalMs;
  lCbInfo.Name:=pVarName;
  lCbInfo.LuaHandlerRef:=pHandlerRef;
  fCallbacks.Add(lId, lCbInfo);
  Glb.DebugLog(Format('Registered variable callback for %s with id %d and interval %d',
    [pVarName, lId, pIntervalMs]), cLoggerXpl);
  lXplObj.Free;
end;

procedure TXPLcontrol.OnXplSyncMessage(Sender: TObject);
var
  lStream: TMemoryStream;
  lMessageType: byte;
begin
  Glb.DebugLog('Sync message from XPL arrived.', cLoggerXpl);
  lStream := TMemoryStream.Create;
  try
    try
      fXplSyncListener.Server.GetMessageData(lStream);
      Glb.DebugLog('Received message with length ' + IntToStr(lStream.Size), cLoggerXpl);
      lStream.Position:=0;
      lMessageType := lStream.ReadByte;
      if (lMessageType = HDMC_RECONNECT) then
      begin
        fXplSender.Reconnect;
      end else if (lMessageType = HDMC_VAR_RESPONSE) then
      begin
        if (fXplVariableValue <> nil) then
        begin
          Glb.LogError(Format('Unprocessed variable value %s', [fXplVariableValue.Name]), cLoggerXpl);
        end
        else
        begin
          fXplVariableValue := TXplVariableValue.Create(lStream);
          Glb.DebugLog('Got variable response, fXplVariableValue set to ' + fXplVariableValue.ToString, cLoggerXpl);
        end;
      end else
        Glb.LogError(Format('Unexpected message from Xplane with type %d', [lMessageType]), cLoggerXpl);
    except
      on E:Exception do
        Glb.LogError(Format('Pipe exception: %s', [E.Message]), cLoggerXpl);
    end;
  finally
    lStream.Free;
  end;
end;

procedure TXPLcontrol.OnXplAsyncMessage(Sender: TObject);
var
  lStream: TMemoryStream;
  lMessageType: byte;
  lVarValue: TXplVariableValue;
  lCallbackInfo: TLmcVariableCallbackInfo;
begin
  Glb.DebugLog('Async message from XPL arrived.', cLoggerXpl);
  lStream := TMemoryStream.Create;
  try
    try
      fXplAsyncListener.Server.GetMessageData(lStream);
      Glb.DebugLog('Received async message with length ' + IntToStr(lStream.Size), cLoggerXpl);
      lStream.Position:=0;
      lMessageType := lStream.ReadByte;
      if (lMessageType = HDMC_RECONNECT) then
      begin
        fXplSender.Reconnect;
      end else if (lMessageType = HDMC_VAR_RESPONSE) then
      begin
        lVarValue := TXplVariableValue.Create(lStream);
        Glb.DebugLog('Got variable response with value ' + lVarValue.ToString, cLoggerXpl);
        lCallbackInfo := fCallbacks.KeyData[lVarValue.Id];
        if (lCallbackInfo = nil) then
          Glb.LogError(Format('Callback for variable %s with id %d not found.', [lVarValue.Name, lVarValue.Id]), cLoggerXpl)
        else
        begin
          Glb.LuaEngine.CallFunctionByRef(lCallbackInfo.LuaHandlerRef, lVarValue, lVarValue.ChangeCount);
        end;
      end else
        Glb.LogError(Format('Unexpected message from Xplane with type %d', [lMessageType]), cLoggerXpl);
    except
      on E:Exception do
        Glb.LogError(Format('Pipe exception: %s', [E.Message]), cLoggerXpl);
    end;
  finally
    lStream.Free;
  end;
end;

function TXPLcontrol.GetXplVariable(pName: String): TXplValue;
var
  lXplObj: TXplGetVariable;
  lId: Int64;
  lDataRead: boolean;
begin
  Result := nil;
  lId := Glb.KeyLogService.UnixTimestampMs;
  lXplObj := TXplGetVariable.Create(pName, lId);
  DebugLog(Format('Sending GetXplVar command for name %s with id %d.', [pName, lXplObj.Id]));
  fXplSender.SendMessage(lXplObj);
  // wait for XPL answer
  lDataRead := fXplSyncListener.Server.PeekMessage(1000, true); // in ms
  // function above should return true when something was read
  // however it seems to return falsi even when onMessage method was called :-(
  // so check also if xpl variable is set with correct id
  // in fact ignore this result, just check fXplVariableValue
  if (fXplVariableValue <> nil) and (fXplVariableValue.Id = lId) then
  begin
    Result := fXplVariableValue.Value;
    // later LUA will call XplVarProcessed
  end
  else
  begin
    Glb.LogError('No value returned from XPL for get variable ' + pName, cLoggerXpl);
    if (fXplVariableValue = nil) then
      Glb.DebugLog('fXplVariableValue is nil', cLoggerXpl)
    else
      Glb.DebugLog('fXplVariableValue has id ' + IntToStr(fXplVariableValue.Id), cLoggerXpl)
  end;
  lXplObj.Free;
end;

procedure TXPLcontrol.SetXplVariable(pName: String; pValue: TXplValue);
var
  lSetVar: TXplSetVariable;
begin
  lSetVar := TXplSetVariable.Create(pName, pValue);
  fXplSender.SendMessage(lSetVar);
  lSetVar.Free;
end;

procedure TXPLcontrol.ExecuteCommand(pCmdName: String);
var
  lXplObj: TXplExecuteCommand;
begin
  lXplObj := TXplExecuteCommand.Create(pCmdName);
  fXplSender.SendMessage(lXplObj);
  lXplObj.Free;
end;

procedure TXPLcontrol.ExecuteCommandBegin(pCmdName: String);
var
  lXplObj: TXplExecuteCommand;
begin
  lXplObj := TXplExecuteCommandBegin.Create(pCmdName);
  fXplSender.SendMessage(lXplObj);
  lXplObj.Free;
end;

procedure TXPLcontrol.ExecuteCommandEnd(pCmdName: String);
var
  lXplObj: TXplExecuteCommand;
begin
  lXplObj := TXplExecuteCommandEnd.Create(pCmdName);
  fXplSender.SendMessage(lXplObj);
  lXplObj.Free;
end;


end.
