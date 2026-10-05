{ SearchIndex — case-folded name search over a FileTree (largest first). }

unit SearchIndex;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, FileTree;

type
  TSearchScope = (ssAll, ssFolders, ssFiles);

  PSearchHit = ^TSearchHit;
  TSearchHit = record
    ID: TNodeID;
    Size: Int64;
  end;

  TSearchIndex = class
  private
    FTree: TFileTree;
    FOwnsTree: Boolean;
    FNames: array of string;
  public
    constructor Create(ATree: TFileTree; OwnsTree: Boolean = False);
    destructor Destroy; override;
    { Caller owns Dest entries (PSearchHit) and must Dispose them. }
    procedure Search(const Query: string; Scope: TSearchScope;
      Dest: TFPList; Limit: Integer = 500);
    property Tree: TFileTree read FTree;
  end;

procedure FreeSearchHits(List: TFPList);

implementation

function FoldName(const S: string): string;
begin
  Result := LowerCase(S);
end;

function HitCompare(Item1, Item2: Pointer): Integer;
var
  A, B: PSearchHit;
begin
  A := PSearchHit(Item1);
  B := PSearchHit(Item2);
  if A^.Size = B^.Size then
    Result := 0
  else if A^.Size > B^.Size then
    Result := -1
  else
    Result := 1;
end;

procedure FreeSearchHits(List: TFPList);
var
  I: Integer;
begin
  for I := 0 to List.Count - 1 do
    Dispose(PSearchHit(List[I]));
  List.Clear;
end;

constructor TSearchIndex.Create(ATree: TFileTree; OwnsTree: Boolean);
var
  I, N: Integer;
begin
  inherited Create;
  FTree := ATree;
  FOwnsTree := OwnsTree;
  N := FTree.NodeCount;
  SetLength(FNames, N);
  for I := 0 to N - 1 do
    FNames[I] := FoldName(FTree.NameOf(I));
end;

destructor TSearchIndex.Destroy;
begin
  if FOwnsTree then
    FTree.Free;
  inherited Destroy;
end;

procedure TSearchIndex.Search(const Query: string; Scope: TSearchScope;
  Dest: TFPList; Limit: Integer);
var
  Tokens: TStringList;
  Folded, Q: string;
  I, T: Integer;
  Match: Boolean;
  Hit: PSearchHit;
  IsDir: Boolean;
begin
  FreeSearchHits(Dest);
  Q := Trim(Query);
  if (Q = '') or (FTree.NodeCount <= 1) then
    Exit;
  Tokens := TStringList.Create;
  try
    Tokens.Delimiter := ' ';
    Tokens.StrictDelimiter := False;
    Tokens.DelimitedText := FoldName(Q);
    for I := 1 to FTree.NodeCount - 1 do
    begin
      IsDir := FTree.IsDirectory(I);
      case Scope of
        ssFolders: if not IsDir then Continue;
        ssFiles: if IsDir then Continue;
        ssAll: ;
      end;
      Folded := FNames[I];
      Match := True;
      for T := 0 to Tokens.Count - 1 do
        if (Tokens[T] <> '') and (Pos(Tokens[T], Folded) = 0) then
        begin
          Match := False;
          Break;
        end;
      if not Match then
        Continue;
      New(Hit);
      Hit^.ID := I;
      Hit^.Size := FTree.SizeOf(I);
      Dest.Add(Hit);
    end;
    Dest.Sort(@HitCompare);
    while Dest.Count > Limit do
    begin
      Dispose(PSearchHit(Dest[Dest.Count - 1]));
      Dest.Delete(Dest.Count - 1);
    end;
  finally
    Tokens.Free;
  end;
end;

end.
