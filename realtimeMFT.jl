# Running notes for creating and testing the script
# cd("C:\\Users\\Dave\\Desktop\\Julia")
# include("realtimeMFT.jl")
# C:\\Users\\Dave\\Desktop\\Julia\\MFT
# C:\\Users\\Dave\\Desktop\\Julia\\test.csv
# Pkg.add("Dates")
# PKg.update()
#print("Enter a mft file location: ")
#mftlocal = readline()
#print("Enter an output file name: ")
#csvOut = readline()
#write(mftlocal)
#write(csvOut)

#import dates module for timestamp converstion
using Dates

#Returns a sub array index in1 to index in2
function subAr(ar::Array{UInt8,1}, in1::Int32, in2::Int32)
  temp = UInt8[]
  for i = in1:in2
    push!(temp, ar[i])
  end
  return temp
end

#converts a byte array to its Int decimal equivalent
function byteAr2num32(ar::Array{UInt8,1})
  num = 0
  for i = 1:length(ar)
    tmp = 0
      tmp |= convert(UInt32, ar[i])
      if i < length(ar)
        for j = 1:(length(ar)-i)
          tmp <<= 8
        end
      end
      num |= tmp
  end
  return num
end

#converts a byte array to its UInt64 decimal equivalent
function byteAr2num64(ar::Array{UInt8,1})
  num::UInt64 = 0
  for i = 1:length(ar)
    tmp::UInt64 = 0
      tmp |= convert(UInt64, ar[i])
      if i < length(ar)
        for j = 1:(length(ar)-i)
          tmp <<= 8
        end
      end
      num |= tmp
  end
  return num
end

#Reverses the endianness of the provided byte array
function reverseEndian(ar::Array{UInt8,1})
  tmp = UInt8[]
  for i = 1:length(ar)
    unshift!(tmp,ar[i])
  end
  return tmp
end

#Returns the MFT record number for the provided entry
function getRecordNum(ar::Array{UInt8,1})
  return byteAr2num32(reverseEndian(ar))
end

#Returns the file/folder allocation state for the provided MFT entry
function getState(ar::Array{UInt8,1})
  st = byteAr2num32(reverseEndian(ar))
  if st == 0
    return "{DEL}File"
  elseif st == 1
    return "File"
  elseif st == 13
    return "{DEL}Directory"
  elseif st == 3
    return "Directory"
  else
    return "Unknown"
  end
end

#converts file time (100 nanosecond ticks from 1-1-1601) to unix time (milliseconds) then to readable time
function int64ToDateTime(ts::UInt64)
  #nano = nano - unix epoch in filetime (nano)
  unix = ts - 116444736000000000
  #seconds = nano/10000000
  unix /= 10000000
  #The division creates a Float64, use round() to return to Int64
  dt = unix2datetime(round(Int64,unix))
  return dt
end

#Function with all necessary sub functions to pars an entries SIA and return the timestamps
function getSIATimestamps(ar::Array{UInt8,1})
  siaStart::Int32 = 57

  function size(ar::Array{UInt8,1}, ind::Int32)
    siaSize = byteAr2num32(reverseEndian(subAr(ar, ind+4, ind+7)))
    return siaSize
  end

  function contentSize(ar::Array{UInt8,1}, ind::Int32)
    siaContentSize = byteAr2num32(reverseEndian(subAr(ar, ind+16, ind+19)))
    return siaContentSize
  end

  function contentStart(ar::Array{UInt8,1}, ind::Int32)
    # 20-23 for XP
    siaContentStart = byteAr2num32(reverseEndian(subAr(ar, ind+20, ind+21)))
    return siaContentStart
  end

  function macFrom32byteAr(ar::Array{UInt8,1})
    mac = DateTime[]
    for i in [1, 9, 17, 25]
      temp = reverseEndian(subAr(ar, i, i+7))
      x = byteAr2num64(temp)
      push!(mac, int64ToDateTime(x))
    end
    #mac[1]=create, mac[2]=file last modified, mac[3]=MFT last modified, mac[4]=file last accessed
    return string(mac[1], ",", mac[2], ",", mac[3], ",", mac[4])
  end
  cstart = siaStart+contentStart(ar, siaStart)
  return macFrom32byteAr(subAr(ar, convert(Int32,cstart), convert(Int32,cstart + 31)))
end

#Extracts the File Name attributes (can be multiple) from the provided MFT entry,
# parsed them, and returns a string array of all attributes.  Additionally, builds
# an index of {record number, parent record, filename} to use for building out paths
function getFNAs(ar::Array{UInt8,1}, rn::UInt32)
  giveback = AbstractString[]
  fnaList = Any[]
  for i = 1:(length(ar)-3)
    tmp = UInt8[]
    if [ar[i],ar[i+1],ar[i+2],ar[i+3]] == [0x30,0x00,0x00,0x00]
      for j = (i+4):(length(ar)-3)
        if [ar[j],ar[j+1],ar[j+2],ar[j+3]] == [0x30,0x00,0x00,0x00] || [ar[j],ar[j+1],ar[j+2],ar[j+3]] == [0x80,0x00,0x00,0x00]
          if length(subAr(ar, i, (j-1))) > 66
            push!(fnaList, subAr(ar, i, (j-1)))
          end
        end
      end
    end
  end

  function fnaLength(ar::Array{UInt8,1})
    tmp = UInt8[]
    tmp = subAr(ar,5,8)
    return byteAr2num32(reverseEndian(tmp))
  end

  function fnaContentSize(ar::Array{UInt8,1})
    tmp = UInt8[]
    tmp = subAr(ar,17,17)
    return byteAr2num32(reverseEndian(tmp))
  end

  function fnaContentStart(ar::Array{UInt8,1})
    tmp = UInt8[]
    tmp = subAr(ar,21,21)
    return byteAr2num32(reverseEndian(tmp))
  end

  function fnaParentRecord(ar::Array{UInt8,1}, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start,start+5)
    return byteAr2num64(reverseEndian(tmp))
  end

  function fnaParentSequence(ar::Array{UInt8,1}, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start+6,start+7)
    return byteAr2num32(reverseEndian(tmp))
  end

  function fnatimestamps(ar::Array{UInt8,1}, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start+8,start+39)
    mac = DateTime[]
    for i in [1, 9, 17, 25]
      temp = reverseEndian(subAr(tmp, i, i+7))
      x = byteAr2num64(temp)
      push!(mac, int64ToDateTime(x))
    end
    #mac[1]=create, mac[2]=file last modified, mac[3]=MFT last modified, mac[4]=file last accessed
    return string(mac[1], ",", mac[2], ",", mac[3], ",", mac[4])
  end

  function sizeOndisk(ar::Array{UInt8,1}, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start+40,start+47)
    return byteAr2num32(reverseEndian(tmp))
  end

  function actualSize(ar::Array{UInt8,1}, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start+48,start+55)
    return byteAr2num32(reverseEndian(tmp))
  end

  function getFilenameLength(ar::Array{UInt8,1}, start::Int32)
    return byteAr2num32(subAr(ar,start+64,start+64))
  end

  function getFileName(ar::Array{UInt8,1}, len::Int32, start::Int32)
    tmp = UInt8[]
    tmp = subAr(ar,start+66,start+66+(len*2)-1)
    nm = ""
    i = 1
    while i <= len*2-1
        nm = nm*string(Char(byteAr2num32(reverseEndian(subAr(tmp, i, i+1)))))
        i += 2
    end
    return nm
  end

  for g = 1:length(fnaList)
    tm = fnaList[g]
    fnal = fnaLength(tm)
    if length(tm) > 66 && length(tm) >= fnal
      contsz = fnaContentSize(tm)
      contstar = convert(Int32,fnaContentStart(tm)) + 1 #added one for test
      if fnal > contsz && fnal < 1024 && contsz > contstar
        par = fnaParentRecord(tm, contstar)
        sod = sizeOndisk(tm, contstar)
        acs = actualSize(tm, contstar)
        name = getFileName(tm, convert(Int32,getFilenameLength(tm, contstar)), contstar)
        times = fnatimestamps(tm, contstar)
        push!(giveback, string(par, ",", sod, ",", acs, ",", name, ",", times))
      end
    end
  end
  return giveback
end

#Parses a single MFT entry and return a string array of its findings
function parseEntry(ent::Array{UInt8,1})
  rec = 0
  sta = ""
  siats = ""
  out = AbstractString[]
  rec = getRecordNum(subAr(ent, 45, 48))
  sta = getState(subAr(ent, 23, 24))
  siats = getSIATimestamps(ent)
  fnas = getFNAs(ent, convert(UInt32,rec))
  for i = 1:length(fnas)
    push!(out, AbstractString(string(rec)* ","* string(sta)* ","* string(siats)* ","* string(fnas[i])* ","))
  end
  return out
end

function buildPaths(ar::Array{AbstractString,1})
  recAr = AbstractString[]
  parAr = AbstractString[]
  nameAr = AbstractString[]
  println("--starting to construct record/parent/name arrays...")
  for i = 1:length(ar)
    tmp = ""
    tmp = ar[i]
    c1st = 0
    c6th = 0
    c7th = 0
    c9th = 0
    c10th = 0
    commacount = 0
    try
      for j = 1:length(tmp)-1
        if tmp[j] == ','
          commacount += 1
          if c1st == 0
            c1st = j
          elseif commacount == 6
            c6th = j
          elseif commacount == 7
            c7th = j
          elseif commacount == 9
            c9th = j
          elseif commacount == 10
            c10th = j
            break
          end
        end
      end
    catch err
      println("An error occured at: ",i, " -- ", err)
    end
    if c1st > 0 && c6th > 0 &&  c7th > 0 && c9th > 0 && c10th > 0
      push!(recAr, tmp[1:c1st-1])
      push!(parAr, tmp[c6th+1:c7th-1])
      push!(nameAr, tmp[c9th+1:c10th-1])
    else
      push!(recAr, "record error")
      push!(parAr, "parent error")
      push!(nameAr, tmp)
    end
  end
  println("--starting to recurse through the arrays...")
  for i = 1:length(recAr)
    function recursePaths(num::Int, rec::AbstractString, par::AbstractString, rAr::Array{AbstractString,1}, pAr::Array{AbstractString,1}, nAr::Array{AbstractString,1}, path::AbstractString)
      if rec == par
        return "{root}"*path*"\n"
      end
      for m = 1:length(ar)
        if par == rAr[m]
          return recursePaths(m, rAr[m], pAr[m], rAr, pAr, nAr, nAr[m]*"\\"*path)
        end
      end
      return "{ORPHAN}\\"*path*"\n"
    end
    ar[i] *= recursePaths(i, recAr[i], parAr[i], recAr, parAr, nameAr, nameAr[i])
  end
  return ar
end

function potentialRecords(file::IOStream)
  count = 0
  temp = stat(mftFile).size
  while temp>0
    temp -= 1024
    count += 1
  end
  return count
end

function loadMFTtoMemory(count::Int32, file::IOStream)
  allEnts = Any[]
  entry = UInt8[]
  for i = 1:count
    entry = readbytes(file, 1024)
    push!(allEnts, entry)
  end
  return allEnts
end

function getMFTpath()
  while(true)
    println("Enter a mft file location: ")
    path = chomp(readline())
    if isfile(path)
      println("...Ok!")
      return path
    else
      println("Error: That is not a valid file. Try again.")
    end
  end
end

function getCSVname(filepath::AbstractString)
  print("Enter an output file name (Excluding the extension): ")
  csv = chomp(readline())
  return dirname(filepath)*"\\"*csv*".csv"
end

function parseMFT(ent::Array{Any, 1})
  parsed = AbstractString[]
  tempEntHolder = UInt8[]
  errorcount = 0
  parsedcount = 0
  for e = 2:length(ent)
    tempEntHolder = ent[e]
    if subAr(tempEntHolder, 1, 5) == [0x46,0x49,0x4c,0x45,0x30]
      temp = parseEntry(tempEntHolder)
      for k = 1:length(temp)
        push!(parsed,temp[k])
      end
      parsedcount += 1
    else
      errorcount += 1
    end
  end
  println("Records parsed: ", parsedcount)
  println("Records skipped (Corrupt or improperly formated): ", errorcount)
  return parsed
end

#------------------------------------------------------------------------------
#
#
#This is the main script for the MFT parser
# all callable functions are above this point
#
#------------------------------------------------------------------------------

#MFT file path and output csv path
#mftlocal = "C:\\Users\\Dave\\Desktop\\Julia\\xp_mft"
#csvOut = "C:\\Users\\Dave\\Desktop\\Julia\\test.csv"

mftlocal = getMFTpath()
csvOut = getCSVname(mftlocal)

#Array of mft entries
mftList = Any[Array{UInt8, 1}]

#single entry array container
mftEntry = Array{UInt8, 1}

#single entry output container
outEntry = Array{AbstractString, 1}

#Opens a stream to the MFT file
mftFile = open(mftlocal)

#Determines the potential number of mft entries
#prints the potential minus 1, since the first record is not
#used in this sense
println("Calculating the potential number of records...")
@time segmentCount = potentialRecords(mftFile)
println("Potential records: ", segmentCount-1)

#load all mft entries into memory
println("Loading MFT into memory...")
@time mftList = loadMFTtoMemory(segmentCount, mftFile)

#Close the stream to the MFT file
close(mftFile)

#Begin Parsing the MFT
println("Parsing the MFT...")
@time outputParsed = parseMFT(mftList)

#Rebuild the file paths from the parsed MFT
println("Recustructing file paths...")
@time outputParsed = buildPaths(outputParsed)

#Open a stream to the output file and
#Write the results to a csv
output = open(csvOut, "a")
unshift!(outputParsed, "Record Number,Allocation State,SIA-Create,SIA-File Modified,SIA-MFT Modified,SIA-Accessed,Parent Record,Size On Disk,Actual Size,Filename,FNA-Create,FNA-File Modified,FNA-MFT Modified,FNA-Accessed,File Path\n")
println("Writing file...")
write(output, outputParsed)
close(output)
println("Complete!")
