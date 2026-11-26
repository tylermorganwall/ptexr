#include "Ptexture.h"
#include <iostream>
int main(int argc, char** argv) {
    if (argc != 2) return 1;
    Ptex::String error;
    PtexPtr<PtexWriter> writer(PtexWriter::open(argv[1], Ptex::mt_quad,
        Ptex::dt_float, 3, -1, 1, error));
    if (!writer) { std::cerr << error.c_str(); return 1; }
    float data[12] = {1,0,0, 0,1,0, 0,0,1, .25f,.5f,.75f};
    if (!writer->writeFace(0, Ptex::FaceInfo(Ptex::Res(1,1)), data)) return 1;
    return writer->close(error) ? 0 : 1;
}
