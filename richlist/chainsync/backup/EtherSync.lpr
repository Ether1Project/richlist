program EtherSync;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, CustApp,
  { you can add units after this }
  StrUtils, Math, DateUtils, IniFiles, SyncObjs,
  // HTTP
  httpsend, ssl_openssl,
  // JSON
  fpjson, jsonparser,
  // MYSQL
  db, sqldb, mysql57conn;
type

  { TEtherSync }

  TEtherSync = class(TCustomApplication)
  private
    FSQLConn: TSQLConnector;
    FSQLQuery: TSQLQuery;
    FSQLTrans: TSQLTransaction;
    FSyncSettings: TIniFile;
    procedure ConnectToMysqlDB;
    procedure DisconnectFromMysqlSB;
    procedure AddTransactionToMysqlDB(const aRecord: TJSONData;
                                      const Timestamp: Double);
    procedure AddToRichListToMysqlDB(const aRecord: TJSONData;
                                     const Timestamp: Double);
    procedure AddFromRichListToMysqlDB(const aRecord: TJSONData;
                                       const Timestamp: Double);
    procedure UpdateToRichListInMysqlDB(const address: string;
                                        const Timestamp: Double);
    procedure UpdateFromRichListInMysqlDB(const address: string;
                                          const Timestamp: Double);
    function FindAddressInMysqlDB(const address: string): Boolean;
    procedure UpdateAddressBalance(const address: string);
    function GetCurrentBlockNumber: Int64;
    procedure SyncEtherBlockchain;
    procedure ShowCurrentBlock;
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
  end;


function HexToDecimal(S: string): Double;
var
  I: Integer;
  Len: Integer;
  Base: Integer;
begin
  Result := 0;

  if Pos('0x', S) = 1 then
    S := Copy(S, 3, Length(S));

  // final length
  Len := Length(S);

  for I := 1 to Len do
  begin
    Base := StrToInt('$' + S[I]);
    Result := Result + (Base * power(16, Len - I));
  end;
end;

{ TEtherSync }

procedure TEtherSync.ConnectToMysqlDB;
begin
  FSQLConn := TSQLConnector.Create(nil);
  FSQLConn.ConnectorType := FSyncSettings.ReadString('database', 'ConnectorType', '');
  FSQLConn.HostName  := FSyncSettings.ReadString('database', 'HostName', '');
  FSQLConn.DatabaseName := FSyncSettings.ReadString('database', 'DatabaseName', '');
  FSQLConn.UserName := FSyncSettings.ReadString('database', 'UserName', '');
  FSQLConn.Password := FSyncSettings.ReadString('database', 'Password', '');

  FSQLTrans := TSQLTransaction.Create(nil);
  FSQLConn.Transaction := FSQLTrans;

  FSQLQuery := TSQLQuery.Create(nil);
  FSQLQuery.Transaction := FSQLTrans;
  FSQLQuery.DataBase := FSQLConn;
  FSQLConn.Open;
end;

procedure TEtherSync.DisconnectFromMysqlSB;
begin
  FSQLConn.Close(False);
  FreeAndNil(FSQLQuery);
  FreeAndNil(FSQLTrans);
  FreeAndNil(FSQLConn);
end;

function TEtherSync.FindAddressInMysqlDB(const address: string): Boolean;
begin
  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('SELECT value FROM richlist where address = :address');
  FSQLQuery.ParamByName('address').AsString := address;
  FSQLQuery.Open;
  try
    FSQLQuery.First;
    Result := not FSQLQuery.EOF;
  finally
    FSQLQuery.Close;
  end;
end;

procedure TEtherSync.AddToRichListToMysqlDB(const aRecord: TJSONData; const Timestamp: Double);
var
  BlockNumber: Int64;
begin
  BlockNumber := Trunc(HexToDecimal(aRecord.FindPath('blockNumber').AsString));

  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('INSERT INTO richlist (address,block,firstIn,lastIn,firstOut,lastOut,numIn,numOut,value) VALUES (:address,:block,:firstIn,:lastIn,:firstOut,:lastOut,:numIn,:numOut,0)');
  FSQLQuery.ParamByName('address').AsString := aRecord.FindPath('to').AsString;
  FSQLQuery.ParamByName('firstIn').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('lastIn').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('block').AsLargeInt := BlockNumber;
  FSQLQuery.ParamByName('firstOut').Value := Null;
  FSQLQuery.ParamByName('lastOut').Value := Null;
  FSQLQuery.ParamByName('numIn').AsInteger := 1;
  FSQLQuery.ParamByName('numOut').AsInteger := 0;
  FSQLQuery.ExecSQL;
end;

procedure TEtherSync.AddFromRichListToMysqlDB(const aRecord: TJSONData; const Timestamp: Double);
var
  BlockNumber: Int64;
begin
  BlockNumber := Trunc(HexToDecimal(aRecord.FindPath('blockNumber').AsString));

  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('INSERT INTO richlist (address,block,firstIn,lastIn,firstOut,lastOut,numIn,numOut,value) VALUES (:address,:block,:firstIn,:lastIn,:firstOut,:lastOut,:numIn,:numOut,0)');
  FSQLQuery.ParamByName('address').AsString := aRecord.FindPath('from').AsString;
  FSQLQuery.ParamByName('firstOut').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('lastOut').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('block').AsLargeInt := BlockNumber;
  FSQLQuery.ParamByName('firstIn').Value := Null;
  FSQLQuery.ParamByName('lastIn').Value := Null;
  FSQLQuery.ParamByName('numIn').AsInteger := 0;
  FSQLQuery.ParamByName('numOut').AsInteger := 1;
  FSQLQuery.ExecSQL;
end;

procedure TEtherSync.AddTransactionToMysqlDB(const aRecord: TJSONData;
                                             const Timestamp: Double);
var
  BlockNumber: Int64;
  FromAddress: TJSONData;
  ToAddress: TJSONData;
begin
  BlockNumber := Trunc(HexToDecimal(aRecord.FindPath('blockNumber').AsString));
  FromAddress := aRecord.FindPath('from');
  ToAddress := aRecord.FindPath('to');

  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('INSERT INTO transactions (hash,block,timestamp,fromaddr,toaddr,value) VALUES (:hash,:block,:timestamp,:fromaddr,:toaddr,:value)');
  FSQLQuery.ParamByName('hash').AsString := aRecord.FindPath('blockHash').AsString;
  FSQLQuery.ParamByName('block').AsLargeInt := BlockNumber;
  FSQLQuery.ParamByName('timestamp').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('value').AsFloat := HexToDecimal(aRecord.FindPath('value').AsString);
  case FromAddress.IsNull of
    False: FSQLQuery.ParamByName('fromaddr').AsString := aRecord.FindPath('from').AsString;
    True: FSQLQuery.ParamByName('fromaddr').Value:= Null;
  end;
  case ToAddress.IsNull of
    False: FSQLQuery.ParamByName('toaddr').AsString := aRecord.FindPath('to').AsString;
    True: FSQLQuery.ParamByName('toaddr').Value:= Null;
  end;
  FSQLQuery.ExecSQL;

  // update the addresses balance
  if not ToAddress.IsNull then
    UpdateAddressBalance(aRecord.FindPath('to').AsString);
  if not FromAddress.IsNull then
    UpdateAddressBalance(aRecord.FindPath('from').AsString);
end;

procedure TEtherSync.UpdateToRichListInMysqlDB(const address: string; const Timestamp: Double);
begin
  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('UPDATE richlist SET numIn = numIn + 1, lastIn = :lastIn, firstIn = if(firstIn is null, :firstIn, firstIn) WHERE address = :address');
  FSQLQuery.ParamByName('firstIn').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('lastIn').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('address').AsString := address;
  FSQLQuery.ExecSQL;
end;

procedure TEtherSync.UpdateFromRichListInMysqlDB(const address: string; const Timestamp: Double);
begin
  FSQLQuery.SQL.Clear;
  FSQLQuery.SQL.Add('UPDATE richlist SET numOut = numOut + 1, lastOut = :lastOut, firstOut = if(firstOut is null, :firstOut, firstOut) WHERE address = :address');
  FSQLQuery.ParamByName('firstOut').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('lastOut').AsDateTime := UnixToDateTime(Trunc(Timestamp));
  FSQLQuery.ParamByName('address').AsString := address;
  FSQLQuery.ExecSQL;
end;

procedure TEtherSync.UpdateAddressBalance(const address: string);
var
  HTTP: THTTPSend;
  Value: Double;
  Options: TJSONArray;
  AResult: TMemoryStream;
  JSONData: TJSONData;
  JSONParser: TJSONParser;
  Parameters: TJSONObject;
  ParametersAsStream: TStringStream;
begin
  Parameters := TJSONObject.Create;
  try
    AResult := TMemoryStream.Create;
    try
      Options := TJSONArray.Create;
      Options.Add(address);
      Options.Add('latest');

      Parameters.Add('jsonrpc', '2.0');
      Parameters.Add('method', 'eth_getBalance');
      Parameters.Add('params', Options);
      Parameters.Add('id', 1);

      HTTP := THTTPSend.Create;
      try
        ParametersAsStream := TStringStream.Create(Parameters.AsJson);
        HTTP.Document.CopyFrom(ParametersAsStream, 0);
        HTTP.MimeType := 'application/json';

        if HTTP.HTTPMethod('POST', FSyncSettings.ReadString('rpc', 'url', '')) then
        begin
          AResult.Size := 0;
          AResult.Seek(0, soFromBeginning);
          AResult.CopyFrom(HTTP.Document, 0);
          AResult.Seek(0, soFromBeginning);
        end
        else
          raise Exception.CreateFmt('No response for address %s', [address]);

        JSONParser := TJSONParser.Create(AResult);
        try
          JSONData := JSONParser.Parse;
          try
            // get the data count
            Value := HexToDecimal(JSONData.FindPath('result').AsString);

            FSQLQuery.SQL.Clear;
            FSQLQuery.SQL.Add('UPDATE richlist SET value = :value WHERE address = :address');
            FSQLQuery.ParamByName('address').AsString := address;
            FSQLQuery.ParamByName('value').AsFloat := Value;
            FSQLQuery.ExecSQL;
          finally
            JSONData.Free;
          end;
        finally
          JSONParser.Free;
        end;
      finally
        HTTP.Free;
      end;
    finally
      AResult.Free;
    end;
  finally
    Parameters := nil;
  end;
end;

function TEtherSync.GetCurrentBlockNumber: Int64;
var
  HTTP: THTTPSend;
  AResult: TMemoryStream;
  JSONData: TJSONData;
  JSONParser: TJSONParser;
  Parameters: TJSONObject;
  ParametersAsStream: TStringStream;
begin
  Parameters := TJSONObject.Create;
  try
    AResult := TMemoryStream.Create;
    try
      Parameters.Add('jsonrpc', '2.0');
      Parameters.Add('method', 'eth_blockNumber');
      Parameters.Add('id', 1);

      HTTP := THTTPSend.Create;
      try
        ParametersAsStream := TStringStream.Create(Parameters.AsJson);
        HTTP.Document.CopyFrom(ParametersAsStream, 0);
        HTTP.MimeType := 'application/json';

        if HTTP.HTTPMethod('POST', FSyncSettings.ReadString('rpc', 'url', '')) then
        begin
          AResult.Size := 0;
          AResult.Seek(0, soFromBeginning);
          AResult.CopyFrom(HTTP.Document, 0);
          AResult.Seek(0, soFromBeginning);
        end
        else
          raise Exception.Create('No response for eth_blockNumber');

        JSONParser := TJSONParser.Create(AResult);
        try
          JSONData := JSONParser.Parse;
          try
            // get the data count
            Result := Trunc(HexToDecimal(JSONData.FindPath('result').AsString));
          finally
            JSONData.Free;
          end;
        finally
          JSONParser.Free;
        end;
      finally
        HTTP.Free;
      end;
    finally
      AResult.Free;
    end;
  finally
    Parameters := nil;
  end;
end;

procedure TEtherSync.SyncEtherBlockchain;
var
  I: Integer;
  HTTP: THTTPSend;
  Options: TJSONArray;
  AResult: TMemoryStream;
  BlockNum: Int64;
  NumTries: Integer;
  JSONData: TJSONData;
  AnAdress: TJSONData;
  Timestamp: Double;
  Processed: Boolean;
  ArrayItem: TJSONData;
  JSONArray: TJSONArray;
  JSONParser: TJSONParser;
  Parameters: TJSONObject;
  ResultData: TJSONObject;
  CurrentBlockNum: Int64;
  ParametersAsStream: TStringStream;
begin
  BlockNum := FSyncSettings.ReadInt64('blockchain', 'lastblock', 1);

  AResult := TMemoryStream.Create;
  try
    ConnectToMysqlDB;
    try
      if not FSQLConn.Connected then
      begin
        writeLn('Could not connect to database. Exiting!');
        Exit;
      end;

      HTTP := THTTPSend.Create;
      try
        while True do
        begin
          CurrentBlockNum := GetCurrentBlockNumber;

          while BlockNum < CurrentBlockNum do
          begin
            Processed := False;
            NumTries := 0;

            while (Processed = False) and (NumTries < 5) do
            begin
              WriteLn(Format('Processing block %d', [BlockNum]));
              try
                // clear the buffers
                HTTP.Document.Clear;
                HTTP.Headers.Clear;
                AResult.Clear;

                Parameters := TJSONObject.Create;
                try
                  // fill opts
                  Options := TJSONArray.Create;
                  Options.Add('0x' + IntToHex(BlockNum, 0));
                  Options.Add(True);

                  // fill params
                  Parameters.Add('jsonrpc', '2.0');
                  Parameters.Add('method', 'eth_getBlockByNumber');
                  Parameters.Add('params', Options);
                  Parameters.Add('id', 1);

                  ParametersAsStream := TStringStream.Create(Parameters.AsJson);
                  HTTP.Document.CopyFrom(ParametersAsStream, 0);
                  HTTP.MimeType := 'application/json';
                finally
                  Parameters.Free;
                end;

                if HTTP.HTTPMethod('POST', FSyncSettings.ReadString('rpc', 'url', '')) then
                begin
                  AResult.Size := 0;
                  AResult.Seek(0, soFromBeginning);
                  AResult.CopyFrom(HTTP.Document, 0);
                  AResult.Seek(0, soFromBeginning);
                end
                else
                  raise Exception.CreateFmt('No response for block %d', [BlockNum]);

                JSONParser := TJSONParser.Create(AResult);
                try
                  JSONData := JSONParser.Parse;
                  try
                    // get the data count
                    ResultData := TJSONObject(JSONData.FindPath('result'));

                    if ResultData <> nil then
                    begin
                      Timestamp := HexToDecimal(ResultData.FindPath('timestamp').AsString);
                      JSONArray := TJSONArray(ResultData.FindPath('transactions'));

                      for I := 0 to JSONArray.Count - 1 do
                      begin
                        FSQLTrans.StartTransaction;

                        ArrayItem := JSONArray.Items[I];
                        // first the recipient address
                        AnAdress := ArrayItem.FindPath('to');

                        if not AnAdress.IsNull then
                        begin
                          // search the richlist for the address
                          if FindAddressInMysqlDB(AnAdress.AsString) then
                            UpdateToRichListInMysqlDB(AnAdress.AsString, Timestamp)
                          else
                            AddToRichListToMysqlDB(ArrayItem, Timestamp);
                        end;

                        // second the sender address
                        AnAdress := ArrayItem.FindPath('from');

                        if not AnAdress.IsNull then
                        begin
                          // search the richlist for the address
                          if FindAddressInMysqlDB(AnAdress.AsString) then
                            UpdateFromRichListInMysqlDB(AnAdress.AsString, Timestamp)
                          else
                            AddFromRichListToMysqlDB(ArrayItem, Timestamp);
                        end;

                        // add the Transaction and balance to the DB
                        AddTransactionToMysqlDB(ArrayItem, Timestamp);
                        // commit the work
                        FSQLTrans.Commit;
                      end;
                    end;
                  finally
                    FreeAndNil(JSONData);
                  end;
                finally
                  FreeAndNil(JSONParser);
                end;

                // block is processed
                Processed := True;
              except
                on E: Exception do
                begin
                  WriteLn(Format('Error syncing the blockchain %s', [E.Message]));
                  Inc(NumTries);
                  Sleep(5000);
                end;
              end;
            end;

            if not Processed then
            begin
              WriteLn(Format('To many tries for block %d', [BlockNum]));
              Exit;
            end;

            // write the last processed block to the ini file and increase it
            FSyncSettings.WriteInt64('blockchain', 'lastblock', BlockNum);
            Inc(BlockNum);
          end;

          // sleep for 2 minutes
          Sleep(120000);
        end;
      finally
        HTTP.Free;
      end;
    finally
      DisconnectFromMysqlSB;
    end;
  finally
    AResult.Free;
  end;
end;

procedure TEtherSync.DoRun;
//var
//  ErrorMsg: String;
begin
  // quick check parameters
  //ErrorMsg := CheckOptions('', ['help','currBlock']);
  //if ErrorMsg<>'' then begin
  //  ShowException(Exception.Create(ErrorMsg));
  //  Terminate;
  //  Exit;
  //end;

  // parse parameters
  if HasOption('h', 'help') then
  begin
    WriteHelp;
    Terminate;
    Exit;
  end;

  // parse parameters
  if HasOption('c', 'currBlock') then
  begin
    ShowCurrentBlock;
    Terminate;
    Exit;
  end;

  { add your program here }
  SyncEtherBlockchain;

  // stop program loop
  Terminate;
end;

constructor TEtherSync.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;

  FSyncSettings := TIniFile.Create(ExtractFilePath(ParamStr(0)) + 'settings.ini');
end;

destructor TEtherSync.Destroy;
begin
  FreeAndNil(FTerminateEvent);
  FreeAndNil(FSyncSettings);

  inherited Destroy;
end;

procedure TEtherSync.ShowCurrentBlock;
begin
  writeln(FSyncSettings.ReadString('blockchain', 'lastblock', ''));
end;

procedure TEtherSync.WriteHelp;
begin
  { add your help code here }
  writeln('Usage: ', ExeName, ' -h');
  writeln('');
  writeln('-currBlock: Write the current block that syning is on');
  writeln('-stop: stops the application');
  writeln('');
end;

var
  Application: TEtherSync;
begin
  Application:=TEtherSync.Create(nil);
  Application.Run;
  Application.Free;
end.
