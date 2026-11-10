import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
T=sys.argv[1]
W,H=1320,2868
PAPER=(0xF6,0xF4,0xEF); INK=(0x14,0x14,0x14); INK2=(0x6E,0x6A,0x62); EMBER=(0xFF,0x5A,0x36)
def font(size,weight):
    f=ImageFont.truetype("/System/Library/Fonts/SFNS.ttf",size)
    try: f.set_variation_by_name(weight)
    except Exception as e: pass
    return f
shots=[("cand/r287.png","Clean up your photos.","Privately.","AI that runs on your iPhone. Nothing is uploaded."),
       ("c3/r0300.0.png","Describe it.","","Type “receipts” and Roll gathers them."),
       ("c2/r0311.0.png","Swipe it.","","Keep or let go. Roll learns as you swipe."),
       ("c2/r0403.0.png","Duplicates,","sorted.","Roll marks the best shot to keep."),
       ("c3/r0355.5.png","Find anything","in plain words.","“Screenshots of chats”: 16 found.")]
for n,(src,l1,l2,sub) in enumerate(shots,1):
    im=Image.new("RGB",(W,H),PAPER); d=ImageDraw.Draw(im)
    hf=font(112,"Bold"); sf=font(50,"Regular")
    y=150
    d.text((W//2,y),l1,font=hf,fill=INK,anchor="ma"); y+=132
    if l2: d.text((W//2,y),l2,font=hf,fill=EMBER,anchor="ma"); y+=132
    y+=24; d.text((W//2,y),sub,font=sf,fill=INK2,anchor="ma")
    top=y+110 if l2 else y+110
    sh=Image.open(f"{T}/shots/{src}").convert("RGB")
    h=H-top-90; w=round(sh.width*h/sh.height)
    sh=sh.resize((w,h),Image.LANCZOS)
    r=78; mask=Image.new("L",(w,h),0); ImageDraw.Draw(mask).rounded_rectangle((0,0,w-1,h-1),r,fill=255)
    x=(W-w)//2
    shadow=Image.new("L",(W,H),0); ImageDraw.Draw(shadow).rounded_rectangle((x,top+18,x+w,top+h+18),r,fill=70)
    shadow=shadow.filter(ImageFilter.GaussianBlur(36))
    im.paste(Image.new("RGB",(W,H),(0,0,0)),(0,0),shadow)
    # border
    ImageDraw.Draw(im).rounded_rectangle((x-6,top-6,x+w+5,top+h+5),r+6,fill=(0xE4,0xE0,0xD8))
    im.paste(sh,(x,top),mask)
    im.save(f"{T}/shots/final/{n:02d}.png")
    print(n,im.size,(w,h),top)
