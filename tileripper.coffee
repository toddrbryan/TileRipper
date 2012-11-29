_ = require 'underscore'
async = require 'async'
request = require 'request'
ArgumentParser = require('argparse').ArgumentParser
fs = require 'fs'

EARTHRADIUS = 6378137
MINLATITUDE = -85.05112878
MAXLATITUDE = 85.05112878
MINLONGITUDE = -180
MAXLONGITUDE = 180
XMIN = -20037507.0671618
XMAX = 20037507.0671618
YMIN = XMIN
YMAX = XMAX

mapSize = (levelOfDetail) ->
  256 << levelOfDetail

clip = (n, min, max) ->
  return Math.min(Math.max(n, min), max)


#Meters per pixel at given latitude
groundResolution = (latitude, levelOfDetail) ->
  latitude = clip latitude, MINLATITUDE, MAXLATITUDE
  Math.cos(latitude * Math.PI / 180) * 2 * Math.PI * EARTHRADIUS / mapSize(levelOfDetail)

mapScale = (latitude, levelOfDetail, screenDpi) ->
  groundResolution(latitude, levelOfDetail) * screenDpi / 0.0254

# /// <summary>
#         /// Converts a point from latitude/longitude WGS-84 coordinates (in degrees)
#         /// into pixel XY coordinates at a specified level of detail.
#         /// </summary>
#         /// <param name="latitude">Latitude of the point, in degrees.</param>
#         /// <param name="longitude">Longitude of the point, in degrees.</param>
#         /// <param name="levelOfDetail">Level of detail, from 1 (lowest detail)
#         /// to 23 (highest detail).</param>
#         /// <param name="pixelX">Output parameter receiving the X coordinate in pixels.</param>
#         /// <param name="pixelY">Output parameter receiving the Y coordinate in pixels.</param>
#   Returns array [pixelx, pixely]
latLongToPixelXY = (latitude, longitude, levelOfDetail) ->
  latitude = clip(latitude, MINLATITUDE, MAXLATITUDE)
  longitude = clip(longitude, MINLONGITUDE, MAXLONGITUDE)

  x = (longitude + 180) / 360 
  sinLatitude = Math.sin(latitude * Math.PI / 180)
  y = 0.5 - Math.log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * Math.PI)

  mapsize = mapSize(levelOfDetail)
  pixelX = Math.floor clip(x * mapsize + 0.5, 0, mapsize - 1)
  pixelY = Math.floor clip(y * mapsize + 0.5, 0, mapsize - 1)
  [pixelX, pixelY]


# /// <summary>
# /// Converts a pixel from pixel XY coordinates at a specified level of detail
# /// into latitude/longitude WGS-84 coordinates (in degrees).
# /// </summary>
# /// <param name="pixelX">X coordinate of the point, in pixels.</param>
# /// <param name="pixelY">Y coordinates of the point, in pixels.</param>
# /// <param name="levelOfDetail">Level of detail, from 1 (lowest detail)
# /// to 23 (highest detail).</param>
# Return [lat, long]
pixelXYToLatLong = (pixelX, pixelY, levelOfDetail) ->
  mapsize = mapSize(levelOfDetail)
  x = (clip(pixelX, 0, mapsize - 1) / mapsize) - 0.5
  y = 0.5 - (clip(pixelY, 0, mapsize - 1) / mapsize)
  latitude = 90 - 360 * Math.atan(Math.exp(-y * 2 * Math.PI)) / Math.PI
  longitude = 360 * x
  [latitude, longitude]

# /// <summary>
# /// Converts pixel XY coordinates into tile XY coordinates of the tile containing
# /// the specified pixel.
# /// </summary>
# /// <param name="pixelX">Pixel X coordinate.</param>
# /// <param name="pixelY">Pixel Y coordinate.</param>
# /// <param name="tileX">Output parameter receiving the tile X coordinate.</param>
# /// <param name="tileY">Output parameter receiving the tile Y coordinate.</param>
pixelXYToTileXY = (pixelX, pixelY) ->
  tileX = Math.floor (pixelX / 256)
  tileY = Math.floor (pixelY / 256)
  [tileX, tileY]

# /// <summary>
# /// Converts tile XY coordinates into pixel XY coordinates of the upper-left pixel
# /// of the specified tile.
# /// </summary>
# /// <param name="tileX">Tile X coordinate.</param>
# /// <param name="tileY">Tile Y coordinate.</param>
# /// <param name="pixelX">Output parameter receiving the pixel X coordinate.</param>
# /// <param name="pixelY">Output parameter receiving the pixel Y coordinate.</param>
tileXYToPixelXY = (tileX, tileY) ->
  pixelX = Math.floor (tileX * 256)
  pixelY = Math.floor (tileY * 256)
  [pixelX, pixelY]

# Returns [xmin, ymin, xmax, ymax]
boundingBoxForTile = (tileX, tileY, levelOfDetail) ->

  longMetersPerTile = (XMAX - XMIN) / (2 << (levelOfDetail-1))
  latMetersPerTile = (YMAX - YMIN) / (2 << (levelOfDetail-1))
  tileAxis = (2 << (levelOfDetail-1))

  minXMeters = XMIN + (tileX * longMetersPerTile)
  maxXMeters = XMIN + (tileX * longMetersPerTile) + longMetersPerTile

  maxYMeters = YMAX - (tileY * latMetersPerTile)
  minYMeters = YMAX - (tileY * latMetersPerTile) - latMetersPerTile

  [minXMeters, minYMeters, maxXMeters, maxYMeters]


checkOutputDirectory = (path, resume) ->
  if fs.existsSync path
    if resume
      console.log "Resuming tiling into #{path}"
    else
      console.log "Output directory #{path} already exists; refusing to overwrite!"
      process.exit()
  else
    if resume 
      console.log "Warning: you have chosen to resume a tilong operation, but your output directory doesn't exist."
    try
      fs.mkdirSync path
    catch e
      console.log "Couldn't create an output directory at #{path}: ", e
      process.exit()    



parser = new ArgumentParser
  version: '0.0.1'
  addHelp:true
  description: 'TileRipper - grab Web Mercator tiles from an ESRI Dynamic Map Service'

parser.addArgument [ '-m', '--mapservice' ], { help: 'Url of the ArcGIS Dynamic Map Service to be cached', metavar: "MAPSERVICEURL", required: true }
parser.addArgument [ '-o', '--output' ], { help: 'Location of generated tile cache', metavar: "OUTPUTFILE", required: true}
parser.addArgument [ '-r', '--resume'] , {help: "Resume ripping or add tiles to an existing tile directory", nargs : 0}
parser.addArgument [ '-z', '--minzoom' ], { help: 'Minimum zoom level to cache', metavar: "ZOOMLEVEL", defaultValue: 1 }
parser.addArgument [ '-Z', '--maxzoom' ], { help: 'Maximum zoom level to cache', metavar: "ZOOMLEVEL" , defaultValue: 23}
parser.addArgument [ '-x', '--westlong' ], { help: 'Westernmost decimal longitude', metavar: "LONGITUDE", required: true }
parser.addArgument [ '-X', '--eastlong' ], { help: 'Easternmost decimal longitude', metavar: "LONGITUDE", required: true }
parser.addArgument [ '-y', '--southlat' ], { help: 'Southernmost decimal latitude', metavar: "LATITUDE", required: true }
parser.addArgument [ '-Y', '--northlat' ], { help: 'Northernmost decimal latitude', metavar: "LATITUDE", required: true }
parser.addArgument [ '-c', '--concurrentops' ], { help: 'Max number of concurrent tile requests', metavar: "REQUESTS", defaultValue: 8 }
parser.addArgument [ '-n', '--noripping' ], { help: "Skip the actual ripping of tiles; just do the tile analysis and report", nargs: 0}

args = parser.parseArgs()

args.westlong = parseFloat args.westlong
args.eastlong = parseFloat args.eastlong
args.northlat = parseFloat args.northlat
args.southlat = parseFloat args.southlat
args.minzoom = parseInt args.minzoom
args.maxzoom = parseInt args.maxzoom
if args.resume then console.log "Resuming tiling operation"

zoomLevel = args.minzoom
totalTiles = 0
missingTiles = 0
while zoomLevel <= args.maxzoom
  console.log "Calculating level #{zoomLevel}"

  nw = latLongToPixelXY args.northlat, args.westlong,  zoomLevel
  ne = latLongToPixelXY args.northlat, args.eastlong,  zoomLevel
  sw = latLongToPixelXY args.southlat, args.westlong,  zoomLevel
  se = latLongToPixelXY args.southlat, args.eastlong,  zoomLevel

  nwtile = pixelXYToTileXY nw[0], nw[1]
  netile = pixelXYToTileXY ne[0], ne[1]
  swtile = pixelXYToTileXY sw[0], sw[1]
  setile = pixelXYToTileXY se[0], se[1]

  ntiles = (setile[0] - nwtile[0] + 1) * (setile[1] - nwtile[1] + 1)
  totalTiles += ntiles

  if args.resume
    for xtile in [nwtile[0]..netile[0]]
      for ytile in [nwtile[1]..swtile[1]]
        if not fs.existsSync "#{args.output}/#{zoomLevel}/#{xtile}/#{ytile}.png" then missingTiles += 1

  zoomLevel = zoomLevel += 1

if args.resume then console.log "Total tiles for cache: #{totalTiles} Number missing from cache: #{missingTiles}"
else console.log "Total tiles to rip: #{missingTiles}"

if args.noripping then process.exit()
if missingTiles <= 0 then process.exit()

checkOutputDirectory args.output, args.resume

queue = async.queue (task, callback) ->
    bbox = boundingBoxForTile task.xtile, task.ytile, task.zoomLevel
    uri = args.mapservice
    uri = uri + "?bbox=#{bbox[0]},#{bbox[1]},#{bbox[2]},#{bbox[3]}"
    uri = uri + "&bboxSR=3857&layers=3&size=256,256&imageSR=3857"
    uri = uri + "&format=png8&transparent=false&dpi=96&f=image"
    #console.log uri
    path = "#{args.output}/#{task.zoomLevel}/#{task.xtile}/#{task.ytile}.png"
    #console.log path
    r = request(uri)
    r.on "end", () ->
      #console.log "End called"
      callback()
    r.pipe(fs.createWriteStream(path))

  , args.concurrentops

queue.drain = () ->
  console.log "Queue drained of all tasks"

zoomLevel = args.minzoom
while zoomLevel <= args.maxzoom
  console.log "Tiling level #{zoomLevel}"
  fs.mkdirSync "#{args.output}/#{zoomLevel}"


  nw = latLongToPixelXY args.northlat, args.westlong,  zoomLevel
  ne = latLongToPixelXY args.northlat, args.eastlong,  zoomLevel
  sw = latLongToPixelXY args.southlat, args.westlong,  zoomLevel
  se = latLongToPixelXY args.southlat, args.eastlong,  zoomLevel
  nwtile = pixelXYToTileXY nw[0], nw[1]
  netile = pixelXYToTileXY ne[0], ne[1]
  swtile = pixelXYToTileXY sw[0], sw[1]
  setile = pixelXYToTileXY se[0], se[1]

  for xtile in [nwtile[0]..netile[0]]
    fs.mkdirSync "#{args.output}/#{zoomLevel}/#{xtile}"
    for ytile in [nwtile[1]..swtile[1]]
      queue.push {xtile: xtile, ytile:ytile, zoomLevel:zoomLevel}, (err) ->
        if err
          console.log err
          process.exit()


  zoomLevel = zoomLevel += 1
