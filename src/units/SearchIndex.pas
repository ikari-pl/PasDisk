{ SearchIndex — name search over a FileTree, largest matches first.

  Port of Services/Search/SearchIndex.swift. Every name is folded once
  (lower case, NFC; ASCII names take a byte fast path) into one blob with a
  0 byte after each name. A query is folded the same way and split on
  whitespace; the longest token is searched through the whole blob, the
  others only inside each name it hits. The root, detached nodes and
  entries outside the scope are skipped. Every hit counts toward
  TotalMatches; the SearchResultLimit largest are kept in a min-size heap
  and returned by size, then name. }

unit SearchIndex;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, FileTree;

const
  SearchResultLimit = 500;

type
  TSearchScope = (ssAll, ssFolders, ssFiles);

  TSearchHit = record
    ID: TNodeID;
    Size: Int64;
  end;
  TSearchHits = array of TSearchHit;

  TSearchResults = record
    { Largest first, ties by name; at most SearchResultLimit entries. }
    Hits: TSearchHits;
    { All matches, including those beyond the limit. }
    TotalMatches: Integer;
  end;

  TSearchIndex = class
  private
    FTree: TFileTree;
    FOwnsTree: Boolean;
    FBlob: string;
    { Byte offset (0-based) of each folded name in FBlob; one extra entry
      marks the end. }
    FOffsets: array of Integer;
    FReachable: TBooleanArray;
  public
    constructor Create(ATree: TFileTree; OwnsTree: Boolean = False);
    destructor Destroy; override;
    function Search(const Query: string; Scope: TSearchScope): TSearchResults;
    property Tree: TFileTree read FTree;
  end;

{ The folded form used for names and queries (exposed for tests). }
function FoldName(const S: string): string;

{ Query tokens: FoldName(Query) split on Unicode whitespace. }
function SearchTokens(const Query: string): TStringArray;

implementation

uses
  PlatformTextFold;

function FoldName(const S: string): string;
var
  I: Integer;
  HasUpper: Boolean;
begin
  HasUpper := False;
  for I := 1 to Length(S) do
    case S[I] of
      #$80..#$FF: Exit(FoldText(S));
      'A'..'Z': HasUpper := True;
    end;
  if not HasUpper then
    Exit(S);
  Result := S;
  UniqueString(Result);
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then
      Result[I] := Chr(Ord(Result[I]) or $20);
end;

{ Length in bytes of the whitespace character at S[I], or 0. Covers what
  Swift's Character.isWhitespace accepts. }
function WhitespaceAt(const S: string; I: Integer): Integer;
var
  B1, B2, B3: Byte;
begin
  Result := 0;
  B1 := Ord(S[I]);
  case B1 of
    9..13, 32: Exit(1);
    $C2:
      if I + 1 <= Length(S) then
      begin
        B2 := Ord(S[I + 1]);
        if (B2 = $85) or (B2 = $A0) then
          Exit(2);
      end;
    $E1, $E2, $E3:
      if I + 2 <= Length(S) then
      begin
        B2 := Ord(S[I + 1]);
        B3 := Ord(S[I + 2]);
        { U+1680 }
        if (B1 = $E1) and (B2 = $9A) and (B3 = $80) then Exit(3);
        if B1 = $E2 then
        begin
          { U+2000..U+200A, U+2028, U+2029, U+202F }
          if (B2 = $80) and ((B3 <= $8A) or (B3 = $A8) or (B3 = $A9) or (B3 = $AF)) then
            Exit(3);
          { U+205F }
          if (B2 = $81) and (B3 = $9F) then Exit(3);
        end;
        { U+3000 }
        if (B1 = $E3) and (B2 = $80) and (B3 = $80) then Exit(3);
      end;
  end;
end;

function SearchTokens(const Query: string): TStringArray;
var
  Folded: string;
  I, W, Start, N: Integer;

  procedure Flush(EndExclusive: Integer);
  begin
    if EndExclusive > Start then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(Folded, Start, EndExclusive - Start);
      Inc(N);
    end;
  end;

begin
  Result := nil;
  N := 0;
  Folded := FoldName(Query);
  Start := 1;
  I := 1;
  while I <= Length(Folded) do
  begin
    W := WhitespaceAt(Folded, I);
    if W > 0 then
    begin
      Flush(I);
      Inc(I, W);
      Start := I;
    end
    else
      Inc(I);
  end;
  Flush(Length(Folded) + 1);
end;

{ True when Needle occurs in the Len bytes at P. }
function ContainsBytes(P: PChar; Len: Integer; const Needle: string): Boolean;
var
  N, I: Integer;
  First: Char;
begin
  N := Length(Needle);
  if N = 0 then
    Exit(True);
  First := Needle[1];
  for I := 0 to Len - N do
    if (P[I] = First) and (CompareByte(P[I], Needle[1], N) = 0) then
      Exit(True);
  Result := False;
end;

{ Min-heap on Size holding the largest SearchResultLimit hits seen. }
type
  TMinSizeHeap = record
    Items: TSearchHits;
    Count: Integer;
  end;

procedure HeapSwap(var H: TMinSizeHeap; A, B: Integer);
var
  T: TSearchHit;
begin
  T := H.Items[A];
  H.Items[A] := H.Items[B];
  H.Items[B] := T;
end;

procedure HeapOffer(var H: TMinSizeHeap; ID: TNodeID; Size: Int64);
var
  Child, Parent, Left, Right, Smallest: Integer;
begin
  if H.Count < SearchResultLimit then
  begin
    if H.Count = Length(H.Items) then
      SetLength(H.Items, SearchResultLimit);
    H.Items[H.Count].ID := ID;
    H.Items[H.Count].Size := Size;
    Child := H.Count;
    Inc(H.Count);
    while Child > 0 do
    begin
      Parent := (Child - 1) div 2;
      if H.Items[Child].Size >= H.Items[Parent].Size then
        Break;
      HeapSwap(H, Child, Parent);
      Child := Parent;
    end;
  end
  else if Size > H.Items[0].Size then
  begin
    H.Items[0].ID := ID;
    H.Items[0].Size := Size;
    Parent := 0;
    repeat
      Left := 2 * Parent + 1;
      Right := Left + 1;
      Smallest := Parent;
      if (Left < H.Count) and (H.Items[Left].Size < H.Items[Smallest].Size) then
        Smallest := Left;
      if (Right < H.Count) and (H.Items[Right].Size < H.Items[Smallest].Size) then
        Smallest := Right;
      if Smallest = Parent then
        Break;
      HeapSwap(H, Parent, Smallest);
      Parent := Smallest;
    until False;
  end;
end;

constructor TSearchIndex.Create(ATree: TFileTree; OwnsTree: Boolean);
var
  I, N, Used, Need: Integer;
  Folded: string;
begin
  inherited Create;
  FTree := ATree;
  FOwnsTree := OwnsTree;
  N := FTree.NodeCount;
  SetLength(FOffsets, N + 1);
  SetLength(FBlob, N * 24);
  Used := 0;
  for I := 0 to N - 1 do
  begin
    FOffsets[I] := Used;
    Folded := FoldName(FTree.NameOf(I));
    Need := Used + Length(Folded) + 1;
    if Need > Length(FBlob) then
      SetLength(FBlob, Need + Need div 2);
    if Folded <> '' then
      Move(Folded[1], FBlob[Used + 1], Length(Folded));
    FBlob[Need] := #0;
    Used := Need;
  end;
  FOffsets[N] := Used;
  SetLength(FBlob, Used);
  FReachable := FTree.ReachabilityBitmap;
end;

destructor TSearchIndex.Destroy;
begin
  if FOwnsTree then
    FTree.Free;
  inherited Destroy;
end;

function TSearchIndex.Search(const Query: string; Scope: TSearchScope): TSearchResults;
var
  Tokens: TStringArray;
  Primary, T: string;
  I, J, Cursor, Found, NameIndex, Start, Len: Integer;
  Heap: TMinSizeHeap;
  MatchesAll: Boolean;
  Size: Int64;

  function HitLess(const A, B: TSearchHit): Boolean;
  begin
    if A.Size <> B.Size then
      Result := A.Size > B.Size
    else
      Result := CompareStr(FTree.NameOf(A.ID), FTree.NameOf(B.ID)) < 0;
  end;

  procedure SortHits(var Hits: TSearchHits; Count: Integer);
  var
    K, L: Integer;
    X: TSearchHit;
  begin
    { At most SearchResultLimit entries: insertion sort is enough. }
    for K := 1 to Count - 1 do
    begin
      X := Hits[K];
      L := K - 1;
      while (L >= 0) and HitLess(X, Hits[L]) do
      begin
        Hits[L + 1] := Hits[L];
        Dec(L);
      end;
      Hits[L + 1] := X;
    end;
  end;

begin
  Result.Hits := nil;
  Result.TotalMatches := 0;
  Tokens := SearchTokens(Query);
  if (Length(Tokens) = 0) or (FTree.NodeCount <= 1) then
    Exit;
  { Longest token first: it narrows the blob sweep the most. }
  for I := 1 to High(Tokens) do
    for J := I downto 1 do
      if Length(Tokens[J]) > Length(Tokens[J - 1]) then
      begin
        T := Tokens[J];
        Tokens[J] := Tokens[J - 1];
        Tokens[J - 1] := T;
      end;
  Primary := Tokens[0];

  Heap.Items := nil;
  Heap.Count := 0;
  NameIndex := 0;
  Cursor := 1;
  while Cursor <= Length(FBlob) do
  begin
    Found := Pos(Primary, FBlob, Cursor);
    if Found = 0 then
      Break;
    while FOffsets[NameIndex + 1] <= Found - 1 do
      Inc(NameIndex);
    Cursor := FOffsets[NameIndex + 1] + 1;

    if (NameIndex = RootID) or not FReachable[NameIndex] then
      Continue;
    case Scope of
      ssFolders: if not FTree.IsDirectory(NameIndex) then Continue;
      ssFiles: if FTree.IsDirectory(NameIndex) then Continue;
      ssAll: ;
    end;
    if Length(Tokens) > 1 then
    begin
      Start := FOffsets[NameIndex];
      Len := FOffsets[NameIndex + 1] - 1 - Start;
      MatchesAll := True;
      for J := 1 to High(Tokens) do
        if not ContainsBytes(@FBlob[Start + 1], Len, Tokens[J]) then
        begin
          MatchesAll := False;
          Break;
        end;
      if not MatchesAll then
        Continue;
    end;
    Inc(Result.TotalMatches);
    Size := FTree.SizeOf(NameIndex);
    if (Heap.Count = SearchResultLimit) and (Size <= Heap.Items[0].Size) then
      Continue;
    HeapOffer(Heap, NameIndex, Size);
  end;

  SortHits(Heap.Items, Heap.Count);
  Result.Hits := Copy(Heap.Items, 0, Heap.Count);
end;

end.
